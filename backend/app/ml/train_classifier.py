"""
Train the Fracta ML claim classifier.
Usage: python -m app.ml.train_classifier
Requires: labeled_claims.csv with columns: text, label
"""
import os
import sys

import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, classification_report
from sklearn.pipeline import Pipeline
import joblib


CSV_PATH = os.path.join(os.path.dirname(__file__), "labeled_claims.csv")
MODEL_PATH = os.path.join(os.path.dirname(__file__), "claim_classifier.pkl")

def train():
    if not os.path.exists(CSV_PATH):
        print(f"ERROR: Training data not found at {CSV_PATH}")
        print("Create labeled_claims.csv with columns: text, label")
        print("Labels: HEALTH_FAKE, SCAM, FINANCIAL_FAKE, POLITICAL_FAKE, COMMUNAL, TRUE")
        sys.exit(1)

    df = pd.read_csv(CSV_PATH)

    if "text" not in df.columns or "label" not in df.columns:
        print("ERROR: CSV must have 'text' and 'label' columns")
        sys.exit(1)

    df = df.dropna(subset=["text", "label"])
    print(f"Loaded {len(df)} labeled examples.")
    print(f"Label distribution:\n{df['label'].value_counts()}\n")

    X = df["text"].astype(str).tolist()
    y = df["label"].astype(str).tolist()

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    pipeline = Pipeline([
        ('tfidf', TfidfVectorizer(max_features=8000, ngram_range=(1,3), 
                                  sublinear_tf=True, min_df=2, analyzer="char_wb")),
        ('clf', LogisticRegression(max_iter=1000, C=1.0, solver='lbfgs', 
                                   multi_class='multinomial', class_weight="balanced", random_state=42))
    ])

    pipeline.fit(X_train, y_train)

    y_pred = pipeline.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    
    print("\nClassification Report:\n")
    print(classification_report(y_test, y_pred))

    joblib.dump(pipeline, MODEL_PATH)

    print(f"Training complete. Accuracy: {accuracy * 100:.2f}%")
    print(f"Model saved as Pipeline to: {MODEL_PATH}")
    print("Run this once before starting backend.")


if __name__ == "__main__":
    train()