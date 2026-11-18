import os
from datetime import datetime
from flask import Flask, request, jsonify
from pymongo import MongoClient

app = Flask(__name__)

# MongoDB configuration
mongodb_uri = os.environ.get("MONGODB_URI", "mongodb://localhost:27017/")
client = MongoClient(mongodb_uri)
db = client["flask_db"]
collection = db["data"]

@app.route("/", methods=["GET"])
def index():
    return f"Welcome to the Flask app! The current time is: {datetime.now()}"

@app.route("/data", methods=["POST"])
def insert_data():
    content = request.get_json(force=True)
    collection.insert_one(content)
    return jsonify({"status": "Data inserted"}), 201

@app.route("/data", methods=["GET"])
def get_data():
    docs = list(collection.find({}, {"_id": 0}))
    return jsonify(docs), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
