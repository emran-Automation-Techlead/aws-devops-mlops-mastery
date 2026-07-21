####################################################################
# PROJECT 1: Hello Cloud
# S3 (storage) + CloudFront (CDN) + ACM (TLS cert) + Route 53 (DNS)
#
# SECURITY NOTE: this uses CloudFront Origin Access Control (OAC),
# not a public S3 bucket + "static website hosting" endpoint. OAC is
# the current AWS-recommended pattern: the bucket stays fully private,
# CloudFront authenticates to it directly, and you still get HTTPS
# between the browser and CloudFront. The legacy "public bucket +
# website endpoint" approach only supports HTTP to the origin and
# requires the bucket to be world-readable — avoid it for anything
# beyond a five-minute experiment.
####################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Primary region for the S3 bucket. Pick whatever you're closest to —
# it doesn't affect global delivery, since CloudFront caches at edges
# worldwide regardless of where the bucket lives.
provider "aws" {
  region = var.aws_region
}

# ACM certificates used by CloudFront MUST be requested in us-east-1,
# no matter what region your bucket is in. This is a hard AWS
# requirement, not a preference — CloudFront is a global service and
# only reads certs from this one region's ACM.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

####################################################################
# Variables
####################################################################

variable "aws_region" {
  description = "Region for the S3 bucket (does not affect CDN reach)"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain to serve the site on, e.g. hello-cloud.example.com. Must already have a Route 53 hosted zone."
  type        = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name. Defaults to the domain name with dots replaced by dashes."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Environment tag, e.g. dev, prod"
  type        = string
  default     = "dev"
}

locals {
  bucket_name = var.bucket_name != "" ? var.bucket_name : replace(var.domain_name, ".", "-")

  common_tags = {
    Project     = "hello-cloud"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

####################################################################
# S3 — the warehouse. Private bucket, versioned (so a bad deploy can
# be rolled back), encrypted at rest.
####################################################################

resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
  tags   = local.common_tags
}

# Versioning is what makes "upload a bad file, roll back instantly"
# possible — without it, overwriting index.html destroys the old copy
# with no way back except redeploying from source.
resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block every form of public access at the bucket level. CloudFront
# reaches this bucket through OAC (below), not through public ACLs —
# so there is no reason for this bucket to ever be world-readable.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

####################################################################
# CloudFront Origin Access Control — lets CloudFront authenticate to
# the private S3 bucket using a signed request, instead of the bucket
# needing to be public.
####################################################################

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Bucket policy: allow GetObject, but ONLY when the request comes from
# this specific CloudFront distribution (enforced via the AWS:SourceArn
# condition). Any other caller — including a random person with the
# bucket name — is denied.
data "aws_iam_policy_document" "site_bucket_policy" {
  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket_policy.json
}

####################################################################
# ACM — the TLS certificate, validated automatically via DNS records
# Terraform creates in your existing Route 53 hosted zone.
####################################################################

data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.primary.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

####################################################################
# CloudFront — the delivery truck network.
####################################################################

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]
  # PriceClass_100 = North America + Europe edge locations only.
  # Cheapest tier; upgrade to PriceClass_All if you need Asia/South
  # America edge coverage too — costs more, not "more correct."
  price_class = "PriceClass_100"
  tags        = local.common_tags

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${local.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${local.bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.site.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # Serve index.html for 404s so client-side routing (if you add it
  # later) doesn't break on refresh. Harmless for a plain static site.
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
}

####################################################################
# Route 53 — the address book. Points the domain at the CloudFront
# distribution using an ALIAS record (free, unlike a CNAME-to-anything
# lookup, and required at the zone apex).
####################################################################

resource "aws_route53_record" "site" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

####################################################################
# Outputs
####################################################################

output "bucket_name" {
  value = aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.site.domain_name
}

output "site_url" {
  value = "https://${var.domain_name}"
}
