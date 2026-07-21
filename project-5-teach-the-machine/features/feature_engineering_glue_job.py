"""
AWS Glue ETL job: reads raw transactions from S3, engineers features,
writes the result back to S3 in Parquet (columnar - what Athena and
SageMaker Feature Store both expect for efficient reads).

Why Glue instead of just running feature_engineering.py locally? At
50,000 rows, pandas on your laptop is plenty. Real fraud-detection
pipelines process transaction volumes pandas can't hold in memory at all
- Glue runs the exact same transformation logic on Spark, scaling from
this dataset to billions of rows without changing the approach, only the
execution engine. Test this script's LOGIC locally (the pure functions
below have no Glue/Spark dependency); the Spark wiring at the bottom is
what actually runs inside the managed Glue job.
"""
import sys

import numpy as np
import pandas as pd


def engineer_features(df: pd.DataFrame) -> pd.DataFrame:
    """Pure pandas transformation - testable without Spark or AWS."""
    df = df.copy()

    # Log-transform amount: fraud amounts are extremely right-skewed
    # (see data/generate_synthetic_data.py) - log scale keeps a few huge
    # outliers from dominating model training the way raw dollars would.
    df["amount_log"] = np.log1p(df["amount"])

    # Cyclical encoding for hour-of-day: hour 23 and hour 0 are ONE hour
    # apart in reality but 23 apart as a raw integer. sin/cos encoding
    # preserves that adjacency for the model.
    df["hour_sin"] = np.sin(2 * np.pi * df["hour_of_day"] / 24)
    df["hour_cos"] = np.cos(2 * np.pi * df["hour_of_day"] / 24)
    df["is_night"] = ((df["hour_of_day"] < 6) | (df["hour_of_day"] >= 22)).astype(int)

    df["high_velocity"] = (df["txn_count_last_hour"] >= 3).astype(int)
    df["far_from_home"] = (df["distance_from_home_km"] > 100).astype(int)
    df["new_card"] = (df["card_age_days"] < 30).astype(int)

    df = pd.get_dummies(df, columns=["merchant_category"], prefix="merchant")

    feature_cols = [
        "transaction_id",
        "amount_log",
        "hour_sin",
        "hour_cos",
        "is_night",
        "txn_count_last_hour",
        "high_velocity",
        "distance_from_home_km",
        "far_from_home",
        "card_age_days",
        "new_card",
    ] + [c for c in df.columns if c.startswith("merchant_")]

    if "is_fraud" in df.columns:
        feature_cols.append("is_fraud")

    return df[feature_cols]


if __name__ == "__main__":
    # Everything below this line only runs inside an actual Glue job -
    # imports are deferred so engineer_features() above can be unit
    # tested (or run locally) without the awsglue library installed.
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.utils import getResolvedOptions
    from pyspark.context import SparkContext
    from pyspark.sql.functions import pandas_udf

    args = getResolvedOptions(sys.argv, ["JOB_NAME", "input_path", "output_path"])

    sc = SparkContext()
    glue_context = GlueContext(sc)
    spark = glue_context.spark_session
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    raw_df = spark.read.option("header", True).option("inferSchema", True).csv(args["input_path"])

    # toPandas() here is a pragmatic simplification for a dataset this
    # size (tens of thousands of rows fit comfortably in driver memory).
    # A genuinely billion-row job would rewrite engineer_features()'s
    # logic in native Spark DataFrame operations instead of pandas -
    # noted here rather than glossed over, since it's the real limit of
    # this approach.
    pandas_df = raw_df.toPandas()
    engineered = engineer_features(pandas_df)
    result_df = spark.createDataFrame(engineered)

    result_df.write.mode("overwrite").parquet(args["output_path"])

    job.commit()
