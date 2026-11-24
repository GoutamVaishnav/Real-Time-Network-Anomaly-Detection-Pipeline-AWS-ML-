# =============================================================================
# cleanup_windows.ps1 — Removes all AWS resources for this project
# Run from PROJECT ROOT: powershell -ExecutionPolicy Bypass -File scripts\cleanup_windows.ps1
# =============================================================================

$REGION     = "us-east-1"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)
$RAW_BUCKET     = "intrusion-detection-raw-$ACCOUNT_ID"
$CURATED_BUCKET = "intrusion-detection-curated-$ACCOUNT_ID"
$MODEL_BUCKET   = "intrusion-detection-models-$ACCOUNT_ID"

Write-Host "Cleaning up all project resources..." -ForegroundColor Red

# Delete Lambda functions
aws lambda delete-function --function-name intrusion-etl-fn     --region $REGION 2>$null
aws lambda delete-function --function-name intrusion-scoring-fn --region $REGION 2>$null
Write-Host "Lambda functions deleted"

# Delete SNS topic
$SNS_ARN = (aws sns list-topics --query "Topics[?contains(TopicArn,'security-alerts')].TopicArn" --output text --region $REGION)
if ($SNS_ARN) { aws sns delete-topic --topic-arn $SNS_ARN --region $REGION }
Write-Host "SNS topic deleted"

# Empty and delete S3 buckets
foreach ($bucket in @($RAW_BUCKET, $CURATED_BUCKET, $MODEL_BUCKET)) {
    aws s3 rm "s3://$bucket" --recursive --region $REGION 2>$null
    aws s3 rb "s3://$bucket" --region $REGION 2>$null
    Write-Host "Bucket $bucket deleted"
}

# Delete IAM roles
foreach ($role in @("intrusion-detection-etl-lambda-role", "intrusion-detection-lambda-role", "intrusion-detection-ec2-role")) {
    aws iam delete-role-policy --role-name $role --policy-name "$role-policy" 2>$null
    aws iam delete-role --role-name $role 2>$null
}
Write-Host "IAM roles deleted"

Write-Host ""
Write-Host "Cleanup complete. All resources removed." -ForegroundColor Green

