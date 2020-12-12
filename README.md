# AWS CloudFormation for Pyramid Analytics

CloudFormation templates and resources to support Pyramid Analytics on the AWS Marketplace at https://aws.amazon.com/marketplace/pp/B08JV8WVVP.

See the marketplace directory.
- Central Instance new repository and Add to Central Instance with nested templates are used within the listing.
- Backup to S3: standalone template to back up the Pyramid repository and EFS service to S3. Can be restored when creating a new Pyramid deployment.
- List of Marketplace AMI Ids for all versions of the Marketplace listing

utilities directory
- bash shell scripts used within the AMI
