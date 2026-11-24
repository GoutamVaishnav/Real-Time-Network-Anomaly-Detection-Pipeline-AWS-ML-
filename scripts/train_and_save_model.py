import pandas as pd
import joblib
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import LabelEncoder

columns = [
    "duration","protocol_type","service","flag","src_bytes","dst_bytes","land",
    "wrong_fragment","urgent","hot","num_failed_logins","logged_in","num_compromised",
    "root_shell","su_attempted","num_root","num_file_creations","num_shells",
    "num_access_files","num_outbound_cmds","is_host_login","is_guest_login","count",
    "srv_count","serror_rate","srv_serror_rate","rerror_rate","srv_rerror_rate",
    "same_srv_rate","diff_srv_rate","srv_diff_host_rate","dst_host_count",
    "dst_host_srv_count","dst_host_same_srv_rate","dst_host_diff_srv_rate",
    "dst_host_same_src_port_rate","dst_host_srv_diff_host_rate","dst_host_serror_rate",
    "dst_host_srv_serror_rate","dst_host_rerror_rate","dst_host_srv_rerror_rate",
    "label","difficulty"
]

df = pd.read_csv("nsl_kdd_train.txt", names=columns)
normal = df[df["label"] == "normal"].sample(2000, random_state=42)
attacks = df[df["label"] != "normal"].sample(200, random_state=42)
sample = pd.concat([normal, attacks]).sample(frac=1, random_state=42).reset_index(drop=True)

X = sample.drop(columns=["label", "difficulty"]).copy()

# Save the encoders too -- Lambda will need the SAME encoding at inference time
encoders = {}
for col in ["protocol_type", "service", "flag"]:
    le = LabelEncoder()
    X[col] = le.fit_transform(X[col])
    encoders[col] = le

model = IsolationForest(n_estimators=200, contamination=0.09, random_state=42)
model.fit(X)

joblib.dump(model, "isolation_forest_model.pkl")
joblib.dump(encoders, "label_encoders.pkl")
joblib.dump(list(X.columns), "feature_columns.pkl")

print("Saved: isolation_forest_model.pkl, label_encoders.pkl, feature_columns.pkl")
print(f"Model trained on {len(X)} records, {X.shape[1]} features")
