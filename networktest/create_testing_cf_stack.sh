aws cloudformation create-stack \
  --stack-name lp-cf-testing \
  --template-body file://$(pwd)/single_instance_with_networktest.template \
  --region us-east-1 \
  --parameters "$(cat cf_testing_params_priv.json)" \
  --capabilities "CAPABILITY_IAM" "CAPABILITY_AUTO_EXPAND" \
  # --debug \

# arn:aws:cloudformation:us-east-1:343272018671:stack/lp-cf-testing-NetworkTestStack-IQ305P7IFCTK/*

#        {
#            "Sid": "VisualEditor3",
#            "Effect": "Allow",
#            "Action": "cloudformation:DeleteStack",
#            "Resource": "arn:aws:cloudformation:us-east-1:343272018671:stack/lp-cf-testing-NetworkTestStack-IQ305P7IFCTK/*"
#        },
