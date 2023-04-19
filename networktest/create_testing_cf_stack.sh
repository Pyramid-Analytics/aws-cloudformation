aws cloudformation create-stack \
  --debug \
  --stack-name lp-cf-testing \
  --template-body file://$(pwd)/single_instance_with_networktest.template \
  --region us-east-1 \
  --parameters "$(cat cf_testing_params.json)" \
  --capabilities "CAPABILITY_IAM" "CAPABILITY_AUTO_EXPAND"

