---
name: bookstack-api
description: "Read, search, or write content in Mathew's self-hosted BookStack wiki at https://author.mathewcsims.uk — a LAN-only project wiki used for writing projects (books, chapters, pages, shelves). Trigger this whenever Mathew asks to look something up in BookStack/'author', draft or file a page/chapter there, search his wiki, or otherwise interact with that instance programmatically. Talk to it directly via its REST API over curl — there is no MCP server for this instance; don't suggest installing one."
---

# BookStack API (author.mathewcsims.uk)

Direct REST API use, no MCP server — this instance's data lives on Mathew's
own Mac/Pi infrastructure (see `~/self-hosted/bookstack/` and
`~/self-hosted/SETUP.md`'s BookStack section), and a plain `curl`-based skill
was the deliberate choice over running a third-party MCP server: no extra
process to trust/patch, same secret-handling discipline as every other admin
script in that repo.

**Reachability: LAN/tailnet only.** The Caddy site block for
`author.mathewcsims.uk` aborts any connection from outside Mathew's home
network or tailnet — this only works when running somewhere with that
access (the Mac itself, or the Pi). If a request hangs or the connection is
refused, that's very likely why; don't debug it as an app-level problem
before confirming network reachability.

## Authentication

The token lives in the "BookStack" Proton Pass item (`Self-Hosted Secrets`
vault), fields `TOKEN_ID` and `TOKEN_SECRET` — fetch it live, the same way
every other script in `~/self-hosted/scripts/` does, never hardcode it or
print it to a terminal/log:

```sh
TOKEN_ID=$(PROTON_PASS_AGENT_REASON="BookStack API call" pass-cli item view \
    --vault-name "Self-Hosted Secrets" --item-title "BookStack" --output json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        if f["name"]=="TOKEN_ID": print(list(f["content"].values())[0])')

TOKEN_SECRET=$(PROTON_PASS_AGENT_REASON="BookStack API call" pass-cli item view \
    --vault-name "Self-Hosted Secrets" --item-title "BookStack" --output json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        if f["name"]=="TOKEN_SECRET": print(list(f["content"].values())[0])')

curl -s -H "Authorization: Token ${TOKEN_ID}:${TOKEN_SECRET}" \
    https://author.mathewcsims.uk/api/books
```

Base URL: `https://author.mathewcsims.uk/api`. Every endpoint below hangs
off that prefix.

## Reading

- `GET /books` / `GET /books/{id}` — list / read a book (a project)
- `GET /chapters` / `GET /chapters/{id}` — list / read a chapter
- `GET /pages` / `GET /pages/{id}` — list / read a page (page read includes
  both `html` and `markdown` fields — prefer `markdown` when re-displaying
  or editing content)
- `GET /shelves` / `GET /shelves/{id}` — list / read a shelf (a group of books)
- `GET /search?query=...&page=1&count=100` — full-text search across
  everything; `query` takes the same syntax as BookStack's own search bar
  (e.g. `{created_by:me}`, `{type:page}` filters)

## Writing

**Pages** — the actual content unit. Needs exactly one parent
(`book_id` OR `chapter_id`, not both) plus `name`, plus exactly one of
`markdown` or `html`:

```sh
curl -s -X POST -H "Authorization: Token ${TOKEN_ID}:${TOKEN_SECRET}" \
    -H "Content-Type: application/json" \
    https://author.mathewcsims.uk/api/pages \
    -d '{"book_id": 1, "name": "Draft outline", "markdown": "# Draft outline\n\n..."}'
```

Update with `PUT /pages/{id}` (same body shape, only send fields you want
changed). Delete with `DELETE /pages/{id}`.

**Books** (`POST /books`, fields: `name` required, `description`/
`description_html`, `tags` array) and **chapters** (`POST /chapters`,
fields: `book_id` + `name` required, same optional fields) follow the same
create/update/delete shape. **Shelves** (`POST /shelves`) group existing
books via a `books` array of book IDs — create the books first.

## Practical notes

- BookStack's taxonomy: Shelf → Book → Chapter → Page. A book doesn't need
  chapters — pages can attach directly to a book for anything that doesn't
  need that extra layer.
- `tags` on any entity is an array of `{name, value}` objects, not plain
  strings.
- No bulk/batch endpoint — creating many pages means many sequential
  `POST /pages` calls.
