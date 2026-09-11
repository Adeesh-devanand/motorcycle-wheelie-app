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


class TemplateControlsTests(unittest.TestCase):
    def setUp(self):
        self.template = yaml.load(TEMPLATE.read_text(), Loader=CloudFormationLoader)

    def test_plain_http_denied_for_bucket_and_objects(self):
        check_tls(self.template)

    def test_negative_controls_reject_guardrail_regressions(self):
        mutations = [
            (check_tls, lambda t: t['Resources']['DiagnosticsBucketPolicy']['Properties']['PolicyDocument']['Statement'][0].update(Effect='Allow')),
            (check_tls, lambda t: t['Resources']['DiagnosticsBucketPolicy']['Properties']['PolicyDocument']['Statement'][0]['Resource'].pop()),
        ]
        for checker, mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = copy.deepcopy(self.template)
                mutate(candidate)
                with self.assertRaises(AssertionError):
                    checker(candidate)


if __name__ == '__main__':
    unittest.main()
