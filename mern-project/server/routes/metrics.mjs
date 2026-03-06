import express from "express";
import client from "prom-client";

const router = express.Router();

// Collect default Node.js metrics (memory, CPU, event loop, etc.)
const register = new client.Registry();
client.collectDefaultMetrics({ register });

// Custom counter for HTTP requests
const httpRequestCounter = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

// Custom histogram for request duration
const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

// Expose the counter and histogram for use in middleware
export { httpRequestCounter, httpRequestDuration };

// GET /metrics — scraped by Prometheus
router.get("/", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

export default router;
