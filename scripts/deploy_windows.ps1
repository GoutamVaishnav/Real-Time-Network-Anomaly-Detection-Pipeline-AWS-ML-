# deploy_windows.ps1 - Run from project root:
# powershell -ExecutionPolicy Bypass -File scripts\deploy_windows.ps1

$YOUR_EMAIL = "apjangid330@gmail.com"   # <-- CHANGE THIS to your email

$REGION     = "us-east-1"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
if (-not $ACCOUNT_ID) { Write-Error "AWS CLI not configured. Run: aws configure"; exit 1 }

$RAW_BUCKET     = "intrusion-detection-raw-" + $ACCOUNT_ID
$CURATED_BUCKET = "intrusion-detection-curated-" + $ACCOUNT_ID
$MODEL_BUCKET   = "intrusion-detection-models-" + $ACCOUNT_ID

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Intrusion Detection Pipeline - AWS Deploy" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Account ID : $ACCOUNT_ID"
Write-Host "Region     : $REGION"
Write-Host ""

# STEP 1: S3 Buckets
Write-Host "[1/9] Creating S3 buckets..." -ForegroundColor Yellow
aws s3 mb ("s3://" + $RAW_BUCKET)     --region $REGION 2>$null
aws s3 mb ("s3://" + $CURATED_BUCKET) --region $REGION 2>$null
aws s3 mb ("s3://" + $MODEL_BUCKET)   --region $REGION 2>$null
Write-Host "  buckets done" -ForegroundColor Green

# STEP 2: Upload model artifacts
Write-Host "[2/9] Uploading model artifacts..." -ForegroundColor Yellow
aws s3 cp model_artifacts\isolation_forest_model.pkl ("s3://" + $MODEL_BUCKET + "/") --region $REGION
aws s3 cp model_artifacts\label_encoders.pkl          ("s3://" + $MODEL_BUCKET + "/") --region $REGION
aws s3 cp model_artifacts\feature_columns.pkl         ("s3://" + $MODEL_BUCKET + "/") --region $REGION
Write-Host "  model artifacts uploaded" -ForegroundColor Green

# STEP 3: SNS topic
Write-Host "[3/9] Creating SNS alert topic..." -ForegroundColor Yellow
$SNS_TOPIC_ARN = (aws sns create-topic --name security-alerts --query TopicArn --output text --region $REGION)
Write-Host "  SNS topic: $SNS_TOPIC_ARN"
aws sns subscribe --topic-arn $SNS_TOPIC_ARN --protocol email --notification-endpoint $YOUR_EMAIL --region $REGION | Out-Null
Write-Host ""
Write-Host "  *** IMPORTANT: Check your email ($YOUR_EMAIL) ***" -ForegroundColor Red
Write-Host "  *** Click the AWS Confirm Subscription link    ***" -ForegroundColor Red
Write-Host ""
Read-Host "  Press ENTER after you confirmed the email"

# STEP 4: IAM trust policy + roles
Write-Host "[4/9] Creating IAM roles..." -ForegroundColor Yellow

$TRUST = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
Set-Content -Path "iam_policies\lambda_trust_policy.json" -Value $TRUST -Encoding ascii

aws iam create-role --role-name intrusion-detection-etl-lambda-role --assume-role-policy-document file://iam_policies/lambda_trust_policy.json 2>$null
aws iam put-role-policy --role-name intrusion-detection-etl-lambda-role --policy-name etl-lambda-policy --policy-document file://iam_policies/iam_lambda_etl_role_policy.json

aws iam create-role --role-name intrusion-detection-lambda-role --assume-role-policy-document file://iam_policies/lambda_trust_policy.json 2>$null
aws iam put-role-policy --role-name intrusion-detection-lambda-role --policy-name scoring-lambda-policy --policy-document file://iam_policies/iam_lambda_role_policy.json

Write-Host "  IAM roles created" -ForegroundColor Green
Write-Host "  Waiting 15s for IAM to propagate..."
Start-Sleep -Seconds 15

# STEP 5: Package Lambda zips (handler only, no deps)
Write-Host "[5/9] Packaging Lambda code..." -ForegroundColor Yellow
if (Test-Path etl_only.zip)     { Remove-Item etl_only.zip }
if (Test-Path scoring_only.zip) { Remove-Item scoring_only.zip }
Compress-Archive -Path lambda_etl_function\etl_handler.py -DestinationPath etl_only.zip
Compress-Archive -Path lambda_function\handler.py         -DestinationPath scoring_only.zip
Write-Host "  zips created" -ForegroundColor Green

# STEP 6: Deploy ETL Lambda
Write-Host "[6/9] Deploying ETL Lambda..." -ForegroundColor Yellow
$ETL_ROLE = "arn:aws:iam::" + $ACCOUNT_ID + ":role/intrusion-detection-etl-lambda-role"
$ETL_ENV  = "Variables={CURATED_BUCKET=" + $CURATED_BUCKET + ",MODEL_BUCKET=" + $MODEL_BUCKET + "}"

aws lambda create-function `
  --function-name intrusion-etl-fn `
  --runtime python3.11 `
  --role $ETL_ROLE `
  --handler etl_handler.lambda_handler `
  --zip-file fileb://etl_only.zip `
  --timeout 60 `
  --memory-size 512 `
  --environment $ETL_ENV `
  --region $REGION 2>$null

aws lambda update-function-code --function-name intrusion-etl-fn --zip-file fileb://etl_only.zip --region $REGION 2>$null
Start-Sleep -Seconds 5

aws lambda update-function-configuration `
  --function-name intrusion-etl-fn `
  --environment $ETL_ENV `
  --layers `
    "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p311-pandas:11" `
    "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p311-scikit-learn:12" `
    "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p311-pyarrow:3" `
  --region $REGION | Out-Null

Write-Host "  intrusion-etl-fn deployed" -ForegroundColor Green

# STEP 7: Deploy Scoring Lambda
Write-Host "[7/9] Deploying Scoring Lambda..." -ForegroundColor Yellow
$SCORING_ROLE = "arn:aws:iam::" + $ACCOUNT_ID + ":role/intrusion-detection-lambda-role"
$SCORING_ENV  = "Variables={MODEL_BUCKET=" + $MODEL_BUCKET + ",SNS_TOPIC_ARN=" + $SNS_TOPIC_ARN + "}"

aws lambda create-function `
  --function-name intrusion-scoring-fn `
  --runtime python3.11 `
  --role $SCORING_ROLE `
  --handler handler.lambda_handler `
  --zip-file fileb://scoring_only.zip `
  --timeout 60 `
  --memory-size 512 `
  --environment $SCORING_ENV `
  --region $REGION 2>$null

aws lambda update-function-code --function-name intrusion-scoring-fn --zip-file fileb://scoring_only.zip --region $REGION 2>$null
Start-Sleep -Seconds 5

aws lambda update-function-configuration `
  --function-name intrusion-scoring-fn `
  --environment $SCORING_ENV `
  --layers `
    "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p311-pandas:11" `
    "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p311-scikit-learn:12" `
  --region $REGION | Out-Null

Write-Host "  intrusion-scoring-fn deployed" -ForegroundColor Green

# STEP 8: S3 triggers
Write-Host "[8/9] Wiring S3 event triggers..." -ForegroundColor Yellow
$ETL_ARN     = (aws lambda get-function --function-name intrusion-etl-fn    --query Configuration.FunctionArn --output text --region $REGION)
$SCORING_ARN = (aws lambda get-function --function-name intrusion-scoring-fn --query Configuration.FunctionArn --output text --region $REGION)

aws lambda add-permission --function-name intrusion-etl-fn --statement-id s3-raw-trigger --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn ("arn:aws:s3:::" + $RAW_BUCKET) --region $REGION 2>$null
aws lambda add-permission --function-name intrusion-scoring-fn --statement-id s3-curated-trigger --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn ("arn:aws:s3:::" + $CURATED_BUCKET) --region $REGION 2>$null

$RAW_NOTIF = '{"LambdaFunctionConfigurations":[{"LambdaFunctionArn":"' + $ETL_ARN + '","Events":["s3:ObjectCreated:*"]}]}'
aws s3api put-bucket-notification-configuration --bucket $RAW_BUCKET --notification-configuration $RAW_NOTIF --region $REGION
Write-Host "  raw bucket trigger set" -ForegroundColor Green

$CURATED_NOTIF = '{"LambdaFunctionConfigurations":[{"LambdaFunctionArn":"' + $SCORING_ARN + '","Events":["s3:ObjectCreated:*"],"Filter":{"Key":{"FilterRules":[{"Name":"suffix","Value":".parquet"}]}}}]}'
aws s3api put-bucket-notification-configuration --bucket $CURATED_BUCKET --notification-configuration $CURATED_NOTIF --region $REGION
Write-Host "  curated bucket trigger set" -ForegroundColor Green

# STEP 9: Test
Write-Host "[9/9] Running test..." -ForegroundColor Yellow
if (Test-Path "scripts\nsl_kdd_train.txt") {
    aws s3 cp scripts\nsl_kdd_train.txt ("s3://" + $RAW_BUCKET + "/batch_001.csv") --region $REGION
    Write-Host "  Test file uploaded! Check Lambda logs in 30 seconds." -ForegroundColor Green
} else {
    Write-Host "  Dataset not found. Download it first, then run:" -ForegroundColor Yellow
    Write-Host "  aws s3 cp scripts\nsl_kdd_train.txt s3://$RAW_BUCKET/batch_001.csv"
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "Raw bucket    : s3://$RAW_BUCKET"
Write-Host "Curated bucket: s3://$CURATED_BUCKET"
Write-Host "Models bucket : s3://$MODEL_BUCKET"
Write-Host "SNS topic     : $SNS_TOPIC_ARN"
Write-Host ""
Write-Host "Watch logs:" -ForegroundColor Cyan
Write-Host "  aws logs tail /aws/lambda/intrusion-etl-fn --follow --region us-east-1"
Write-Host "  aws logs tail /aws/lambda/intrusion-scoring-fn --follow --region us-east-1"
