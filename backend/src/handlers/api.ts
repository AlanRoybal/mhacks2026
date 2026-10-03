// Lambda entry for API Gateway (HTTP API, payload v2).
import { handle } from "hono/aws-lambda";
import { createApp } from "../api/app.js";
import { getDeps } from "../deps.js";

export const handler = handle(createApp(getDeps()));
