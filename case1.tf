# Configure the AWS Provider
provider "aws" {
  region = "us-west-2"  # Change this to your desired region
}

# S3 
resource "aws_s3_bucket" "bronze_bucket" {
  bucket = "your-bronze-layer-bucket",
  description = "S3 para guardar texto plano (JSON) extrída de la API"
}

#S3
resource "aws_s3_bucket" "silver_bucket" {
  bucket = "your-silver-layer-bucket",
  description = "S3 para guardar la data procesesada de la capa de Bronce"
}

# Redshift cluster para la capa de oro
resource "aws_redshift_cluster" "gold_cluster" {
  cluster_identifier = "gold-layer-cluster"
  database_name      = "golddb"
  master_username    = "admin"
  master_password    = "admin"  
  node_type          = "dc2.large"
  cluster_type       = "single-node",
  description = "Redshift para guardar los data mart provenientes de la capa silver , fácil integración para las herramientas de BI"
}

# Lambda functions 
resource "aws_lambda_function" "data_processing_lambdas" {
  count         = 16
  filename      = "lambda_function_table_${count.index + 1}_payload.zip"  
  function_name = "data-processing-lambda-table-${count.index + 1}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.10" 
  s3_bucket     = "lambda_functios_zip"  
  s3_key        = "lambda_function_table_${count.index + 1}_payload.zip"  
  description   = "Esta es la función Lambda para extraer los datos de la tabla ${count.index + 1} que registran no más de 1000 registros diarios. Los archivos"
}

# IAM 
resource "aws_iam_role" "lambda_role" {
  name = "data-processing-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# AWS Batch 
resource "aws_batch_job_definition" "batch_job_definition" {
  name        = "data-extraction-job-transaction-table"
  type        = "container"
  container_properties = jsonencode({
    image         = "<your_ecr_repository_uri_extraction_table>:<tag>" 
    vcpus         = 1
    memory        = 1024
    command       = ["python main.py"]
  })

  retry_strategy {
    attempts = 1
  }
  description = "Para la extracción de la tabla de transacciones que requiere un tiempo más prolongado de ejecución."
}

resource "aws_batch_job_definition" "batch_job_definition" {
  name        = "data-transform-job-bronce-to-silver"
  type        = "container"
  container_properties = jsonencode({
    image         = "<your_ecr_repository_uri_transform_bronce_silver>:<tag>" 
    vcpus         = 1
    memory        = 1024
    command       = ["python main.py"]
  })

  retry_strategy {
    attempts = 1
  }
  description = "Para transformar los datos de la capa de bronce a silver en formato delta"
}

resource "aws_batch_job_definition" "batch_job_definition" {
  name        = "data-transform-job-silver-to-gold"
  type        = "container"
  container_properties = jsonencode({
    image         = "<your_ecr_repository_uri_transform_silver_gold>:<tag>" 
    vcpus         = 1
    memory        = 1024
    command       = ["python main.py"]
  })

  retry_strategy {
    attempts = 1
  }
  description = "Para ingestar de la capa silver a la capa gold"
}

# IAM role for Batch
resource "aws_iam_role" "batch_service_role" {
  name = "batch-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "batch.amazonaws.com"
        }
      }
    ]
  })
}

# Step Functions 
resource "aws_sfn_state_machine" "data_pipeline_sfn" {
  name     = "data-pipeline-state-machine"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    "Comment": "Data Pipeline Workflow",
    "StartAt": "ParallelExtraction",
    "States": {
      "ParallelExtraction": {
        "Type": "Parallel",
        "Branches": [
          {
            "StartAt": "ExtractTransactionTable",
            "States": {
              "ExtractTransactionTable": {
                "Type": "Task",
                "Resource": "arn:aws:states:::batch:submitJob.sync",
                "Parameters": {
                  "JobDefinition": "${aws_batch_job_definition.batch_job_definition_extraction.arn}",
                  "JobName": "ExtractTransactionTable",
                  "JobQueue": "${aws_batch_job_queue.job_queue.arn}"
                },
                "End": true
              }
            }
          },
          {
            "StartAt": "ExecuteLambdaFunctions",
            "States": {
              "ExecuteLambdaFunctions": {
                "Type": "Parallel",
                "Branches": [
                  for i in range(16) : {
                    "StartAt": "Lambda${i + 1}",
                    "States": {
                      "Lambda${i + 1}": {
                        "Type": "Task",
                        "Resource": "${aws_lambda_function.data_processing_lambdas[i].arn}",
                        "End": true
                      }
                    }
                  }
                ],
                "End": true
              }
            }
          }
        ],
        "Next": "TransformBronzeToSilver"
      },
      "TransformBronzeToSilver": {
        "Type": "Task",
        "Resource": "arn:aws:states:::batch:submitJob.sync",
        "Parameters": {
          "JobDefinition": "${aws_batch_job_definition.batch_job_definition_bronze_to_silver.arn}",
          "JobName": "TransformBronzeToSilver",
          "JobQueue": "${aws_batch_job_queue.job_queue.arn}"
        },
        "Next": "TransformSilverToGold"
      },
      "TransformSilverToGold": {
        "Type": "Task",
        "Resource": "arn:aws:states:::batch:submitJob.sync",
        "Parameters": {
          "JobDefinition": "${aws_batch_job_definition.batch_job_definition_silver_to_gold.arn}",
          "JobName": "TransformSilverToGold",
          "JobQueue": "${aws_batch_job_queue.job_queue.arn}"
        },
        "End": true
      }
    }
  })
}


# IAM role for Step Functions
resource "aws_iam_role" "step_functions_role" {
  name = "step-functions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
}

# Note: You'll need to add appropriate IAM policies to these roles
# to allow the services to interact with each other and access necessary resources.