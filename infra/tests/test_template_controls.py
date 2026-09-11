"""Offline infrastructure regressions; no credentials or AWS calls required."""
import copy
import json
from pathlib import Path
import unittest
import yaml


class CloudFormationLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag: value}


CloudFormationLoader.add_multi_constructor('!', intrinsic)
TEMPLATE = Path(__file__).resolve().parents[1] / 'diagnostic-upload.yaml'


def check_tls(template):
    policy = template['Resources']['DiagnosticsBucketPolicy']['Properties']
    assert policy['Bucket'] == {'Ref': 'DiagnosticsBucket'}
    deny = policy['PolicyDocument']['Statement'][0]
    assert deny['Effect'] == 'Deny' and deny['Principal'] == '*'
    assert deny['Action'] == 's3:*'
    assert deny['Condition'] == {'Bool': {'aws:SecureTransport': 'false'}}
    assert deny['Resource'] == [
        {'GetAtt': 'DiagnosticsBucket.Arn'},
        {'Sub': '${DiagnosticsBucket.Arn}/*'},
    ]


def check_logs(template):
    resources = template['Resources']
    logs = resources['DefaultStage']['Properties']['AccessLogSettings']
    assert logs['DestinationArn'] == {'GetAtt': 'ApiAccessLogGroup.Arn'}
    fields = json.loads(logs['Format'])
    assert fields == {
        'requestId': '$context.requestId',
        'status': '$context.status',
        'responseLatency': '$context.responseLatency',
    }
    assert resources['ApiAccessLogGroup']['Properties']['RetentionInDays'] == 14


def check_alarms(template):
    resources = template['Resources']
    specs = {
        'ApiServerErrorsAlarm': ('AWS/ApiGateway', '5xx', 'ApiId', 'HttpApi', 1),
        'ApiClientErrorsAlarm': ('AWS/ApiGateway', '4xx', 'ApiId', 'HttpApi', 20),
        'PresignErrorsAlarm': ('AWS/Lambda', 'Errors', 'FunctionName', 'PresignFunction', 1),
        'PresignThrottlesAlarm': ('AWS/Lambda', 'Throttles', 'FunctionName', 'PresignFunction', 1),
    }
    for name, (namespace, metric, dimension, ref, threshold) in specs.items():
        alarm = resources[name]['Properties']
        assert alarm['Namespace'] == namespace and alarm['MetricName'] == metric
        assert alarm['Dimensions'] == [{'Name': dimension, 'Value': {'Ref': ref}}]
        assert alarm['Statistic'] == 'Sum' and alarm['Period'] == 300
        assert alarm['Threshold'] == threshold and alarm['EvaluationPeriods'] == 1
        assert alarm['ComparisonOperator'] == 'GreaterThanOrEqualToThreshold'
        assert alarm['TreatMissingData'] == 'notBreaching'
        assert alarm['AlarmActions'] == {'If': [
            'HasAlarmTopic', [{'Ref': 'AlarmTopicArn'}], {'Ref': 'AWS::NoValue'}]}
    assert template['Parameters']['AlarmTopicArn']['Default'] == ''
    assert template['Conditions']['HasAlarmTopic'] == {
        'Not': [{'Equals': [{'Ref': 'AlarmTopicArn'}, '']}]}


class TemplateControlsTests(unittest.TestCase):
    def setUp(self):
        self.template = yaml.load(TEMPLATE.read_text(), Loader=CloudFormationLoader)

    def test_plain_http_denied_for_bucket_and_objects(self):
        check_tls(self.template)

    def test_access_logs_only_contain_operational_allowlist(self):
        check_logs(self.template)

    def test_alarms_have_correct_metrics_and_optional_real_actions(self):
        check_alarms(self.template)

    def test_negative_controls_reject_guardrail_regressions(self):
        mutations = [
            (check_tls, lambda t: t['Resources']['DiagnosticsBucketPolicy']['Properties']['PolicyDocument']['Statement'][0].update(Effect='Allow')),
            (check_tls, lambda t: t['Resources']['DiagnosticsBucketPolicy']['Properties']['PolicyDocument']['Statement'][0]['Resource'].pop()),
            (check_logs, lambda t: t['Resources']['DefaultStage']['Properties']['AccessLogSettings'].update(Format='{"ip":"$context.identity.sourceIp"}')),
            (check_alarms, lambda t: t['Resources']['ApiServerErrorsAlarm']['Properties'].update(MetricName='5XXError')),
            (check_alarms, lambda t: t['Resources']['PresignErrorsAlarm']['Properties'].update(AlarmActions=[])),
            (check_alarms, lambda t: t['Resources']['ApiServerErrorsAlarm']['Properties'].update(Dimensions=[{'Name': 'ApiName', 'Value': {'Ref': 'HttpApi'}}])),
        ]
        for checker, mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = copy.deepcopy(self.template)
                mutate(candidate)
                with self.assertRaises(AssertionError):
                    checker(candidate)


if __name__ == '__main__':
    unittest.main()
