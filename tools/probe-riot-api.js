// Read-only probe for the local Riot Client API (lockfile auth).
// Usage: node tools/probe-riot-api.js [method] [path] [body]
const fs = require("fs");
const path = require("path");
const https = require("https");

const lockPath = path.join(process.env.LOCALAPPDATA, "Riot Games", "Riot Client", "Config", "lockfile");
const parts = fs.readFileSync(lockPath, "utf8").trim().split(":");
const port = Number(parts[2]);
const password = parts[3];
const auth = "Basic " + Buffer.from("riot:" + password).toString("base64");

function request(method, urlPath, body) {
  return new Promise((resolve) => {
    const req = https.request(
      {
        host: "127.0.0.1",
        port,
        path: urlPath,
        method,
        rejectUnauthorized: false,
        headers: {
          Authorization: auth,
          "Content-Length": body ? Buffer.byteLength(body) : 0,
        },
      },
      (res) => {
        let data = "";
        res.on("data", (d) => (data += d));
        res.on("end", () => resolve({ status: res.statusCode, body: data }));
      }
    );
    req.on("error", (e) => resolve({ error: e.message }));
    req.end(body || "");
  });
}

(async () => {
  const method = (process.argv[2] || "GET").toUpperCase();
  const target = process.argv[3];
  const body = process.argv[4] || "";
  if (target) {
    const r = await request(method, target, body);
    console.log(JSON.stringify({ method, target, status: r.status, error: r.error, body: (r.body || "").slice(0, 4000) }, null, 2));
    return;
  }
  const paths = [
    "/riot-client-lifecycle/v1/ux-command",
    "/riotclient/lifecycle/v1/ux-command",
    "/riotclient/ux-command",
    "/riotclient/v1/ux-command",
    "/riotclient/app-port",
    "/riotclient/command-line-args",
  ];
  for (const p of paths) {
    const r = await request("GET", p);
    const b = (r.body || "").replace(/\s+/g, " ").slice(0, 220);
    console.log("GET " + p + " -> " + (r.status || r.error) + " | " + b);
  }
})();
