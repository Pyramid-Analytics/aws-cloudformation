# Pyramid AWS Marketplace AMI Ids

As new versions of Pyramid's AWS Marketplace listing is released, new AMIs containing the updated Pyramid software are created
for each region. Updated AMI Ids need to be used in CloudFormation templates.

To be inserted into your CloudFormation templates via:

```
AMIID: !FindInMap 
  - AWSAMIRegionMap
  - !Ref 'AWS::Region'
  - '64'
```

This directory has a file per Pyramid AWS Marketplace release.
