#!/bin/bash
# ==============================================================================
# Deployment script: Real-Time Intrusion Detection Pipeline (FREE-TIER VERSION)
# Uses two Lambda functions (ETL + scoring) instead of AWS Glue, so the entire
# pipeline stays within AWS's Always-Free limits -- no paid services required.
# Requires the AWS CLI configured with sufficient permissions to create IAM
# roles, S3 buckets, Lambda functions, and SNS topics.
# ==============================================================================

set -e

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
RAW_BUCKET="intrusion-detection-raw-${ACCOUNT_ID}"
CURATED_BUCKET="intrusion-detection-curated-${ACCOUNT_ID}"
MODEL_BUCKET="intrusion-detection-models-${ACCOUNT_ID}"

echo "=== Step 1: Create S3 buckets (raw, curated, models) ==="
aws s3 mb "s3://${RAW_BUCKET}" --region "$REGION"
aws s3 mb "s3://${CURATED_BUCKET}" --region "$REGION"
aws s3 mb "s3://${MODEL_BUCKET}" --region "$REGION"

echo "=== Step 2: Upload trained model artifacts ==="
aws s3 cp model_artifacts/isolation_forest_model.pkl "s3://${MODEL_BUCKET}/"
aws s3 cp model_artifacts/feature_columns.pkl "s3://${MODEL_BUCKET}/"
aws s3 cp model_artifacts/label_encoders.pkl "s3://${MODEL_BUCKET}/"

echo "=== Step 3: Create SNS topic for alerts ==="
SNS_TOPIC_ARN=$(aws sns create-topic --name security-alerts --query TopicArn --output text)
echo "SNS topic created: ${SNS_TOPIC_ARN}"
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "your-email@example.com"
echo ">>> Check your email and confirm the SNS subscription before testing <<<"

echo "=== Step 4: Create IAM role for the ETL Lambda ==="
aws iam create-role \
  --role-name intrusion-detection-etl-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }'
aws iam put-role-policy \
  --role-name intrusion-detection-etl-lambda-role \
  --policy-name intrusion-detection-etl-lambda-policy \
  --policy-document file://iam_policies/iam_lambda_etl_role_policy.json

echo "=== Step 5: Create IAM role for the scoring Lambda ==="
aws iam create-role \
  --role-name intrusion-detection-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }'
aws iam put-role-policy \
  --role-name intrusion-detection-lambda-role \
  --policy-name intrusion-detection-lambda-policy \
  --policy-document file://iam_policies/iam_lambda_role_policy.json

echo "=== Step 6: Package and deploy the ETL Lambda ==="
bash scripts/package_lambda.sh etl

aws lambda create-function \
  --function-name intrusion-etl-fn \
  --runtime python3.11 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/intrusion-detection-etl-lambda-role" \
  --handler etl_handler.lambda_handler \
  --zip-file fileb://etl_lambda_deployment_package.zip \
  --timeout 60 \
  --memory-size 512 \
  --environment "Variables={CURATED_BUCKET=${CURATED_BUCKET},MODEL_BUCKET=${MODEL_BUCKET}}"

echo "=== Step 7: Package and deploy the scoring Lambda ==="
bash scripts/package_lambda.sh scoring

aws lambda create-function \
  --function-name intrusion-scoring-fn \
  --runtime python3.11 \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/intrusion-detection-lambda-role" \
  --handler handler.lambda_handler \
  --zip-file fileb://scoring_lambda_deployment_package.zip \
  --timeout 60 \
  --memory-size 512 \
  --environment "Variables={MODEL_BUCKET=${MODEL_BUCKET},SNS_TOPIC_ARN=${SNS_TOPIC_ARN}}"

echo "=== Step 8: Grant S3 permission to invoke both Lambdas ==="
aws lambda add-permission \
  --function-name intrusion-etl-fn \
  --statement-id s3-invoke-etl \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${RAW_BUCKET}"

aws lambda add-permission \
  --function-name intrusion-scoring-fn \
  --statement-id s3-invoke-scoring \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${CURATED_BUCKET}"

echo "=== Step 9: Wire the S3 triggers ==="
ETL_LAMBDA_ARN=$(aws lambda get-function --function-name intrusion-etl-fn --query Configuration.FunctionArn --output text)
SCORING_LAMBDA_ARN=$(aws lambda get-function --function-name intrusion-scoring-fn --query Configuration.FunctionArn --output text)

# Raw bucket -> triggers ETL Lambda on any new upload
aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
      "LambdaFunctionArn": "'"${ETL_LAMBDA_ARN}"'",
      "Events": ["s3:ObjectCreated:*"]
    }]
  }'

# Curated bucket -> triggers scoring Lambda when ETL writes Parquet output
aws s3api put-bucket-notification-configuration \
  --bucket "$CURATED_BUCKET" \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [{
      "LambdaFunctionArn": "'"${SCORING_LAMBDA_ARN}"'",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {"Key": {"FilterRules": [{"Name": "suffix", "Value": ".parquet"}]}}
    }]
  }'

echo "=== Step 10: (Optional) Launch EC2 dashboard instance ==="
echo "Create instance manually via console (see BUILD_GUIDE.md Part 9), or:"
echo "aws ec2 run-instances --image-id ami-xxxxxxxx --instance-type t3.micro \\"
echo "  --iam-instance-profile Name=intrusion-detection-ec2-profile \\"
echo "  --key-name your-key-pair --security-groups your-sg"

echo ""
echo "=== Deployment complete -- fully within AWS Always-Free limits ==="
echo "Raw bucket:      s3://${RAW_BUCKET}"
echo "Curated bucket:  s3://${CURATED_BUCKET}"
echo "Model bucket:    s3://${MODEL_BUCKET}"
echo "SNS topic:       ${SNS_TOPIC_ARN}"
echo ""
echo "Test it: upload a CSV to s3://${RAW_BUCKET}/, and the whole pipeline"
echo "fires automatically -- ETL Lambda cleans it, scoring Lambda scores it,"
echo "SNS emails you if anomalies are found. No manual job to run."
