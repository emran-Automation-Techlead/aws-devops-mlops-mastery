const request = require("supertest");
const app = require("../app/app");

// TDD mindset: these tests describe the contract the API must honor. They
// run in CI on every push - a broken contract fails the build BEFORE it
// ever reaches CodeBuild, let alone production.
beforeEach(() => {
  app.__resetTasks();
});

describe("GET /health", () => {
  it("returns 200 ok", async () => {
    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });
});

describe("GET /tasks", () => {
  it("returns the seeded tasks", async () => {
    const res = await request(app).get("/tasks");
    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(2);
  });
});

describe("GET /tasks/:id", () => {
  it("returns a single task", async () => {
    const res = await request(app).get("/tasks/1");
    expect(res.status).toBe(200);
    expect(res.body.title).toBe("Set up CI/CD pipeline");
  });

  it("returns 404 for a missing task", async () => {
    const res = await request(app).get("/tasks/999");
    expect(res.status).toBe(404);
  });
});

describe("POST /tasks", () => {
  it("creates a task", async () => {
    const res = await request(app).post("/tasks").send({ title: "Ship it" });
    expect(res.status).toBe(201);
    expect(res.body.title).toBe("Ship it");
    expect(res.body.done).toBe(false);
  });

  it("rejects a missing title", async () => {
    const res = await request(app).post("/tasks").send({});
    expect(res.status).toBe(400);
  });
});

describe("PUT /tasks/:id", () => {
  it("updates a task's done flag", async () => {
    const res = await request(app).put("/tasks/1").send({ done: true });
    expect(res.status).toBe(200);
    expect(res.body.done).toBe(true);
  });

  it("returns 404 for a missing task", async () => {
    const res = await request(app).put("/tasks/999").send({ done: true });
    expect(res.status).toBe(404);
  });

  it("rejects a non-boolean done value", async () => {
    const res = await request(app).put("/tasks/1").send({ done: "yes" });
    expect(res.status).toBe(400);
  });
});

describe("DELETE /tasks/:id", () => {
  it("deletes a task", async () => {
    const res = await request(app).delete("/tasks/1");
    expect(res.status).toBe(204);

    const check = await request(app).get("/tasks/1");
    expect(check.status).toBe(404);
  });

  it("returns 404 for a missing task", async () => {
    const res = await request(app).delete("/tasks/999");
    expect(res.status).toBe(404);
  });
});
