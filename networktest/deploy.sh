#!/bin/bash
aws s3 cp network-test.yaml s3://pyramid-cloudformation/submodules/network-test/network-test.yaml
aws s3 cp pyramid-single-instance-testing.yaml s3://pyramid-cloudformation/templates/pyramid-single-instance-testing.yaml
aws s3 cp pyramid-base-resources-parameters.yaml s3://pyramid-cloudformation/templates/pyramid-base-resources-parameters-testing.yaml
