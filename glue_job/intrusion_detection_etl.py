"""
AWS Glue ETL job: intrusion_detection_etl
Reads raw network logs from S3, cleans + encodes them, writes curated Parquet.

Deploy: upload this file to s3://<your-scripts-bucket>/glue_scripts/intrusion_detection_etl.py
        then create the Glue job pointing at that script location (see deploy.sh)
"""
import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, when
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["JOB_NAME", "RAW_PATH", "CURATED_PATH"])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

RAW_PATH = args["RAW_PATH"]          # e.g. s3://intrusion-detection-raw/incoming/
CURATED_PATH = args["CURATED_PATH"]  # e.g. s3://intrusion-detection-curated/

FEATURE_COLUMNS = [
    "duration", "protocol_type", "service", "flag", "src_bytes", "dst_bytes",
    "count", "srv_count", "serror_rate", "srv_serror_rate", "same_srv_rate",
    "diff_srv_rate", "dst_host_count", "dst_host_srv_count",
]

CATEGORICAL_COLUMNS = ["protocol_type", "service", "flag"]

# --- Extract ---
raw_df = spark.read.option("header", "true").option("inferSchema", "true").csv(RAW_PATH)

# --- Transform ---
clean_df = raw_df.select(*FEATURE_COLUMNS)

# Drop rows with nulls in critical fields rather than silently corrupting downstream scoring
clean_df = clean_df.dropna(subset=FEATURE_COLUMNS)

# Encode categorical columns to numeric codes (StringIndexer-equivalent, kept simple/explicit)
from pyspark.ml.feature import StringIndexer

for cat_col in CATEGORICAL_COLUMNS:
    indexer = StringIndexer(inputCol=cat_col, outputCol=f"{cat_col}_idx", handleInvalid="keep")
    clean_df = indexer.fit(clean_df).transform(clean_df)
    clean_df = clean_df.drop(cat_col).withColumnRenamed(f"{cat_col}_idx", cat_col)

clean_df = clean_df.withColumn("ingest_ts", F.current_timestamp())

# --- Load ---
clean_df.write.mode("append").partitionBy("ingest_ts").parquet(CURATED_PATH)

job.commit()
