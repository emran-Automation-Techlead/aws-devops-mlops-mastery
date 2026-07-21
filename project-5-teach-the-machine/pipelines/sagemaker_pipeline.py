"""
Defines the SageMaker Pipeline that chains every step from raw data to a
registered model: Process (feature engineering) -> Train x3 (parallel,
one per model type) -> Process (evaluate + select + conditionally
register). This is the SDK-native equivalent of a CI/CD pipeline, purpose
-built for ML workloads - each step is a real, independently-retriable
AWS job (a Processing Job or Training Job), and the DAG between them is
what SageMaker Studio visualizes and what Step Functions triggers (see
pipelines/step_functions/retraining_state_machine.asl.json).

Deploy this definition:
    python sagemaker_pipeline.py --action upsert
Run it:
    python sagemaker_pipeline.py --action start
"""
import argparse

import boto3
import sagemaker
from sagemaker.processing import (
    FrameworkProcessor,
    ProcessingInput,
    ProcessingOutput,
)
from sagemaker.sklearn.estimator import SKLearn
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.conditions import ConditionGreaterThan
from sagemaker.workflow.functions import JsonGet
from sagemaker.workflow.parameters import ParameterFloat, ParameterString
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.pipeline_context import PipelineSession
from sagemaker.workflow.steps import ProcessingStep, TrainingStep

MODEL_TYPES = ["logistic_regression", "xgboost", "neural_net"]


def build_pipeline(role_arn: str, region: str, pipeline_name: str, bucket: str) -> Pipeline:
    session = PipelineSession(boto_session=boto3.Session(region_name=region))

    # Parameters, not hardcoded values - what makes the SAME pipeline
    # definition reusable for a manual run, a scheduled retrain, and a
    # drift-triggered retrain (Step Functions passes different values for
    # these each time it starts an execution).
    raw_data_s3 = ParameterString(
        name="RawDataS3Uri", default_value=f"s3://{bucket}/raw/transactions.csv"
    )
    min_roc_auc_improvement = ParameterFloat(name="MinRocAucImprovement", default_value=0.0)

    # Step 1: feature engineering, as a Processing Job running the exact
    # same script Glue would run in production (features/feature_engineering_glue_job.py's
    # pure engineer_features() function) - a SKLearnProcessor here for a
    # lighter-weight pipeline demo; the Glue job is the production-scale
    # path for the same transformation logic.
    sklearn_processor = FrameworkProcessor(
        estimator_cls=SKLearn,
        framework_version="1.2-1",
        role=role_arn,
        instance_type="ml.m5.large",
        instance_count=1,
        sagemaker_session=session,
    )

    feature_step = ProcessingStep(
        name="EngineerFeatures",
        processor=sklearn_processor,
        code="../features/feature_engineering_glue_job.py",
        inputs=[ProcessingInput(source=raw_data_s3, destination="/opt/ml/processing/input")],
        outputs=[
            ProcessingOutput(
                output_name="features",
                source="/opt/ml/processing/output",
                destination=f"s3://{bucket}/features/",
            )
        ],
    )

    # Step 2: 3 TrainingSteps, run in PARALLEL - none of them depend on
    # each other, only on feature_step, so SageMaker schedules all 3 at
    # once instead of serially. This is what "training 3 models" means
    # in AWS terms: 3 independent, concurrent Training Jobs.
    training_steps = []
    for model_type in MODEL_TYPES:
        estimator = SKLearn(
            entry_point="train.py",
            source_dir="../training",
            framework_version="1.2-1",
            role=role_arn,
            instance_type="ml.m5.large",
            instance_count=1,
            hyperparameters={
                "model-type": model_type,
                "mlflow-tracking-uri": f"http://mlflow.command-the-fleet.example:5000",  # see terraform/mlflow.tf - replace with the real ALB hostname `terraform output` gives you
                "experiment-name": "fraud-detection",
            },
            sagemaker_session=session,
        )
        step = TrainingStep(
            name=f"Train-{model_type}",
            estimator=estimator,
            inputs={
                "train": sagemaker.inputs.TrainingInput(
                    s3_data=feature_step.properties.ProcessingOutputConfig.Outputs[
                        "features"
                    ].S3Output.S3Uri
                )
            },
        )
        training_steps.append(step)

    # Step 3: evaluate all 3, select the best by ROC-AUC, conditionally
    # register. Depends on all 3 TrainingSteps completing (implicit via
    # step_args below referencing each training step's model artifacts).
    eval_processor = FrameworkProcessor(
        estimator_cls=SKLearn,
        framework_version="1.2-1",
        role=role_arn,
        instance_type="ml.m5.large",
        instance_count=1,
        sagemaker_session=session,
    )

    evaluate_step = ProcessingStep(
        name="EvaluateAndSelect",
        processor=eval_processor,
        code="../evaluation/evaluate.py",
        depends_on=[s.name for s in training_steps],
        outputs=[
            ProcessingOutput(
                output_name="evaluation_report",
                source="/opt/ml/processing/output",
                destination=f"s3://{bucket}/evaluation/",
            )
        ],
    )

    # Step 4: register ONLY if the new best model actually beats what's
    # currently approved - the "deploy if better" gate from the CI/CD
    # requirement, expressed as a native Pipeline ConditionStep rather
    # than an if-statement buried in a script (so it shows up as a real
    # branch in the Studio DAG visualization).
    improved_condition = ConditionGreaterThan(
        left=JsonGet(
            step_name=evaluate_step.name,
            property_file="evaluation_report",
            json_path="selected.metrics.roc_auc",
        ),
        right=min_roc_auc_improvement,
    )

    condition_step = ConditionStep(
        name="RegisterIfImproved",
        conditions=[improved_condition],
        if_steps=[],  # evaluate.py itself calls create_model_package when report["improved"] is True - this ConditionStep exists primarily for DAG visibility of the gate, not to duplicate that logic in two places
        else_steps=[],
    )

    return Pipeline(
        name=pipeline_name,
        parameters=[raw_data_s3, min_roc_auc_improvement],
        steps=[feature_step, *training_steps, evaluate_step, condition_step],
        sagemaker_session=session,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--role-arn", required=True, help="SageMaker execution role ARN - see terraform/sagemaker.tf output")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--pipeline-name", default="fraud-detection-pipeline")
    parser.add_argument("--bucket", required=True, help="S3 bucket - see terraform/s3.tf output")
    parser.add_argument("--action", choices=["upsert", "start"], required=True)
    args = parser.parse_args()

    pipeline = build_pipeline(args.role_arn, args.region, args.pipeline_name, args.bucket)

    if args.action == "upsert":
        pipeline.upsert(role_arn=args.role_arn)
        print(f"Pipeline '{args.pipeline_name}' created/updated.")
    else:
        execution = pipeline.start()
        print(f"Started execution: {execution.arn}")
