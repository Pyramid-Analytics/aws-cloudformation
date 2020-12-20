from flask import Flask, Response
from smart_open import open


s3server = Flask(__name__)
@s3server.route('/')
def hello_world():
    return "Hello World!"

@s3server.route('/s3get/<path:bucketFolderFile>',  methods=["GET"])
def get_s3_file(bucketFolderFile):
    s3server.logger.info('s3get: ' + bucketFolderFile)

    def generate():
        for line in open('s3://' + bucketFolderFile):
            yield line
    return Response(generate())

if __name__ == '__main__':
    s3server.run(host='0.0.0.0')
