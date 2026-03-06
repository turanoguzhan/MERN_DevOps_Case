import React, { useEffect, useState } from "react";

export default function HealthStatus() {
  const [status, setStatus] = useState([]);

  const API_URL = process.env.REACT_APP_API_URL || "http://localhost:5050";

  useEffect(() => {
    fetch(`${API_URL}/healthcheck/`)
      .then((response) => response.json())
      .then((data) => setStatus(data));
  }, [API_URL]);

  return (
    <div>
      <h3>API Status</h3>
      {JSON.stringify(status)}
    </div>
  );
}
