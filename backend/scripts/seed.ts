// Seeds a running backend through its public API, so it works against local dev or a deployed stage
// (which must have DEMO_MODE=true and a DEMO_LOGIN_KEY for demo login and fake funding).
//
//   npm run seed                                  # http://localhost:8787
//   BASE_URL=https://xxxx.execute-api.us-east-1.amazonaws.com DEMO_LOGIN_KEY=... npm run seed
//
// Creates four seed posters with twelve funded jobs around Ann Arbor, plus a "demo-designer" worker
// whose twin comes from a LinkedIn export, so the twin screen shows LinkedIn-sourced skills.

import { strToU8, zipSync } from "fflate";

const BASE_URL = (process.env.BASE_URL ?? "http://localhost:8787").replace(/\/$/, "");
const HOURS = 3600_000;

type Json = Record<string, any>;

async function call(method: string, path: string, token?: string, body?: unknown): Promise<Json> {
  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(process.env.DEMO_LOGIN_KEY ? { "x-demo-key": process.env.DEMO_LOGIN_KEY } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const json = text ? (JSON.parse(text) as Json) : {};
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`);
  return json;
}

const login = async (handle: string, displayName: string) => (await call("POST", "/auth/demo", undefined, { handle, displayName })).token as string;

// Around Ann Arbor: Diag, Kerrytown, Burns Park, North Campus, Old West Side.
const PLACES = {
  diag: { latitude: 42.2768, longitude: -83.7382, address: "The Diag, Ann Arbor" },
  kerrytown: { latitude: 42.2846, longitude: -83.7457, address: "Kerrytown, Ann Arbor" },
  burnsPark: { latitude: 42.2652, longitude: -83.7302, address: "Burns Park, Ann Arbor" },
  northCampus: { latitude: 42.2917, longitude: -83.7152, address: "North Campus, Ann Arbor" },
  oldWest: { latitude: 42.2799, longitude: -83.7577, address: "Old West Side, Ann Arbor" },
};

const JOBS: { poster: number; hours: number; job: Json }[] = [
  { poster: 1, hours: 6, job: { title: "Mow front lawn", description: "Small front yard, mower is in the garage. Please bag the clippings.", category: "YARD_WORK", location: PLACES.burnsPark, payAmount: 35 } },
  { poster: 1, hours: 24, job: { title: "Rake leaves in the backyard", description: "Rake and bag the leaves; bags are by the back door.", category: "YARD_WORK", location: PLACES.burnsPark, payAmount: 25 } },
  { poster: 1, hours: 30, job: { title: "Assemble an IKEA bookshelf", description: "BILLY bookshelf, all parts and tools are here. Anchor it to the wall.", category: "HOME", location: PLACES.oldWest, payAmount: 30 } },
  { poster: 2, hours: 3, job: { title: "Sketch a logo for a coffee shop", description: 'Paper sketch of a logo for "Bean There." Any style; include the name.', category: "DESIGN", location: null, payAmount: 15 } },
  { poster: 2, hours: 48, job: { title: "Design event poster concepts", description: "Three poster concepts for a jazz night at a student club. PDF or PNG.", category: "DESIGN", location: null, payAmount: 45 } },
  { poster: 2, hours: 20, job: { title: "Photograph a vintage desk", description: "Five well-lit photos for a Marketplace listing, including drawers open.", category: "PHOTOGRAPHY", location: PLACES.kerrytown, payAmount: 28 } },
  { poster: 3, hours: 12, job: { title: "Calc II tutoring, 1 hour", description: "Series convergence tests before Friday's exam. Video call is fine.", category: "TUTORING", location: null, payAmount: 25 } },
  { poster: 3, hours: 36, job: { title: "Fix a bug in my portfolio site", description: "The contact form doesn't send. Fix it and share the commit link.", category: "TECHNOLOGY", location: null, payAmount: 60 } },
  { poster: 3, hours: 10, job: { title: "Proofread a cover letter", description: "One page. Track changes or comments in a Google Doc.", category: "OTHER", location: null, payAmount: 10 } },
  { poster: 4, hours: 5, job: { title: "Pick up groceries from Kroger", description: "List of 12 items; I'll pay for the groceries separately. Leave them at the door.", category: "ERRANDS", location: PLACES.northCampus, payAmount: 18 } },
  { poster: 4, hours: 26, job: { title: "Help move a couch upstairs", description: "One couch, second floor, no elevator. Two people would help.", category: "MOVING", location: PLACES.diag, payAmount: 40 } },
  { poster: 4, hours: 28, job: { title: "Set up a Wi-Fi mesh network", description: "Three-node mesh, already bought. Cover the basement office.", category: "TECHNOLOGY", location: PLACES.kerrytown, payAmount: 35 } },
];

const LINKEDIN_SKILLS = ["Graphic Design", "Logo Design", "Adobe Illustrator", "Brand Identity", "Illustration", "Product Photography", "Typography"];

async function seedDesigner(): Promise<void> {
  const token = await login("demo-designer", "Maya R.");
  const zip = zipSync({
    "Skills.csv": strToU8(`Name\n${LINKEDIN_SKILLS.join("\n")}\n`),
    "Positions.csv": strToU8("Company Name,Title,Description,Location,Started On,Finished On\nMichigan Daily,Graphic Designer,Designed covers and logos,Ann Arbor,Sep 2024,\n"),
  });
  const upload = await call("POST", "/uploads/presign", token, { contentType: "application/zip" });
  const put = await fetch(upload.uploadURL, { method: "PUT", headers: upload.headers, body: zip });
  if (!put.ok) throw new Error(`upload failed: ${put.status}`);
  await call("POST", "/twin/ingest", token, { blobKey: upload.blobKey, kind: "linkedin_zip" });
  await call("PUT", "/twin/prefs", token, { base: { latitude: PLACES.diag.latitude, longitude: PLACES.diag.longitude }, minPay: 10, maxRadiusMiles: 5 });
  console.log("  demo-designer: twin imported from a LinkedIn export (add a device token by signing in on a phone)");
}

async function main(): Promise<void> {
  console.log(`Seeding ${BASE_URL}`);
  await call("GET", "/health");
  const posters = await Promise.all([1, 2, 3, 4].map((n) => login(`seed-poster-${n}`, ["Jordan K.", "Priya S.", "Sam T.", "Alex P."][n - 1] ?? "Poster")));
  for (const { poster, hours, job } of JOBS) {
    const token = posters[poster - 1] ?? "";
    const deadline = new Date(Date.now() + hours * HOURS).toISOString().replace(/\.\d{3}Z$/, "Z");
    const draft = await call("POST", "/jobs", token, { ...job, deadline, currency: "USD", posterPhotos: [] });
    const funded = await call("POST", `/demo/jobs/${draft.id}/fund`, token);
    console.log(`  ${funded.status.padEnd(8)} $${String(job.payAmount).padStart(3)}  ${job.title}`);
  }
  await seedDesigner();
  console.log("Done.");
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
