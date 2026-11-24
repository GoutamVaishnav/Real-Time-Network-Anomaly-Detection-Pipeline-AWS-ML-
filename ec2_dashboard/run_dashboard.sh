#!/bin/bash
# Run this ON the EC2 instance (via EC2 Instance Connect) after uploading dashboard.py.
# Installs dependencies and starts the dashboard on port 80.

set -e

echo "Installing dependencies..."
sudo yum install -y python3-pip -q
pip3 install --user streamlit pandas boto3 pyarrow -q

echo "Setting the curated bucket name..."
read -p "Enter your curated bucket name (e.g. intrusion-detection-curated-123456789012): " BUCKET
export CURATED_BUCKET="$BUCKET"

echo "Starting dashboard on port 80 (requires the security group to allow inbound HTTP)..."
echo "Access it at http://<your-ec2-public-ip>"
echo "Press Ctrl+C to stop, or run with nohup to keep it running after disconnecting:"
echo "  nohup streamlit run dashboard.py --server.port 80 --server.address 0.0.0.0 > dashboard.log 2>&1 &"
echo ""

~/.local/bin/streamlit run dashboard.py --server.port 80 --server.address 0.0.0.0
