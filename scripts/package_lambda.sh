#!/bin/bash
# Packages a Lambda function + its Python dependencies into a deployable zip.
# Usage:
#   bash scripts/package_lambda.sh etl      -> builds etl_lambda_deployment_package.zip
#   bash scripts/package_lambda.sh scoring  -> builds scoring_lambda_deployment_package.zip
# Run from the project root.

set -e

TARGET="$1"
if [ "$TARGET" != "etl" ] && [ "$TARGET" != "scoring" ]; then
  echo "Usage: bash scripts/package_lambda.sh [etl|scoring]"
  exit 1
fi

if [ "$TARGET" == "etl" ]; then
  SRC_DIR="lambda_etl_function"
  HANDLER_FILE="etl_handler.py"
  OUTPUT_ZIP="etl_lambda_deployment_package.zip"
else
  SRC_DIR="lambda_function"
  HANDLER_FILE="handler.py"
  OUTPUT_ZIP="scoring_lambda_deployment_package.zip"
fi

BUILD_DIR="lambda_build_${TARGET}"
rm -rf "$BUILD_DIR" "$OUTPUT_ZIP"
mkdir -p "$BUILD_DIR"

echo "Installing dependencies into build directory..."
pip install pandas scikit-learn joblib pyarrow \
  --target "$BUILD_DIR" \
  --break-system-packages -q

echo "Copying handler code..."
cp "${SRC_DIR}/${HANDLER_FILE}" "$BUILD_DIR/"

echo "Zipping deployment package..."
cd "$BUILD_DIR"
zip -r "../${OUTPUT_ZIP}" . -q
cd ..

echo "Package created: ${OUTPUT_ZIP} ($(du -h "$OUTPUT_ZIP" | cut -f1))"
echo ""
echo "NOTE: pandas/scikit-learn/pyarrow together often exceed Lambda's 250MB"
echo "unzipped limit. If deployment fails on size, use a Lambda Layer for these"
echo "dependencies instead of bundling them directly, or switch to a"
echo "container-image Lambda (aws lambda create-function --package-type Image)."
