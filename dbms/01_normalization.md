# 01 · Normalization: Rewind Database ("Ctrl+Z for databases")

Rewind records every change made to a table, so we can see the table as it was at any past time, see who changed what, and undo mistakes. The demo table is `employees`.

We start from how the data would look if someone kept it in one sheet, and normalize it step by step: **UNF → 1NF → 2NF → 3NF → BCNF**.

---

## 0. Unnormalized form (UNF): one sheet

One row per employee. The change history is crammed into one cell.

| emp_id | name | email | department | current_salary | changes |
|--------|------|-------|------------|---------------:|---------|
| 101 | Asha Rao | asha@corp.in | Sales | 60000 | 2026-01-05 10:00 INSERT 50000 by priya (admin); 2026-03-01 09:30 UPDATE 50000→60000 by rahul (editor) |
| 102 | Vikram Shah | vikram@corp.in | IT | 0 | 2026-01-05 10:05 INSERT 70000 by priya (admin); 2026-04-10 17:02 UPDATE 70000→0 by rahul (editor) |

**Problems:** the `changes` cell is a **repeating group** (many values in one cell). You cannot query "all changes by rahul" or "salary as of 1 March" without parsing text. A deleted employee's row disappears together with its whole history.

---

## 1. First Normal Form (1NF)

**Rule:** every cell holds one value, no repeating groups, and every row has a key.

We split the `changes` cell so that **one row = one version of an employee**.

**employee_versions** (key: `emp_id, version_no`)

| emp_id | version_no | name | email | department | salary | current_salary | operation | changed_at | changed_by | changer_role |
|--------|-----------:|------|-------|------------|-------:|---------------:|-----------|------------|------------|--------------|
| 101 | 1 | Asha Rao | asha@corp.in | Sales | 50000 | 60000 | INSERT | 2026-01-05 10:00 | priya | admin |
| 101 | 2 | Asha Rao | asha@corp.in | Sales | 60000 | 60000 | UPDATE | 2026-03-01 09:30 | rahul | editor |
| 102 | 1 | Vikram Shah | vikram@corp.in | IT | 70000 | 0 | INSERT | 2026-01-05 10:05 | priya | admin |
| 102 | 2 | Vikram Shah | vikram@corp.in | IT | 0 | 0 | UPDATE | 2026-04-10 17:02 | rahul | editor |

Each version stores a **full copy of the row** (name, email, department, salary), because any column can change and a restore needs the whole old row.

**Functional dependencies**
- FD1: `emp_id, version_no → name, email, department, salary, operation, changed_at, changed_by`
- FD2: `emp_id → current_salary` (the current value does not depend on the version)
- FD3: `changed_by → changer_role`

This is in 1NF, but FD2 and FD3 cause anomalies:
- **Update anomaly:** when Vikram's salary is fixed, `current_salary` must be changed in *every* one of his rows.
- **Insert anomaly:** we cannot record a new user (for example a new admin) until that user changes something.
- **Delete anomaly:** if we purge old versions, we also lose who the users are and what role they have.

---

## 2. Second Normal Form (2NF)

**Rule:** 1NF, and no non-key column depends on only *part* of a composite key.

FD2 (`emp_id → current_salary`) is a **partial dependency**: it depends on `emp_id` alone, not on `(emp_id, version_no)`. The same is true for all the *current* values of an employee. We move the current state to its own table:

**employees** (key: `emp_id`): the live table that the app reads and writes

| emp_id | name | email | department | salary |
|--------|------|-------|------------|-------:|
| 101 | Asha Rao | asha@corp.in | Sales | 60000 |
| 102 | Vikram Shah | vikram@corp.in | IT | 0 |

**employees_history** (key: `emp_id, version_no`): every version, ever

| emp_id | version_no | name | email | department | salary | operation | changed_at | changed_by | changer_role |
|--------|-----------:|------|-------|------------|-------:|-----------|------------|------------|--------------|
| 101 | 1 | Asha Rao | asha@corp.in | Sales | 50000 | INSERT | 2026-01-05 10:00 | priya | admin |
| 101 | 2 | Asha Rao | asha@corp.in | Sales | 60000 | UPDATE | 2026-03-01 09:30 | rahul | editor |
| … | | | | | | | | | |

Now each non-key column depends on the whole key. The history keeps no foreign key to `employees`, on purpose: when an employee row is **deleted**, its history must stay so the row can be restored.

---

## 3. Third Normal Form (3NF)

**Rule:** 2NF, and no non-key column depends on another non-key column (**no transitive dependency**).

In `employees_history`, FD3 still holds: `changed_by → changer_role`. So `emp_id, version_no → changed_by → changer_role` is **transitive**. If Rahul is promoted to admin, every history row of his would have to be updated, and some would be missed.

We move users to their own table and store only a reference in the history:

**users** (key: `user_id`)

| user_id | username | role |
|--------:|----------|------|
| 1 | priya | admin |
| 2 | rahul | editor |
| 3 | meera | viewer |

**employees_history** (key: `history_id`; `changed_by` → `users.user_id`)

| history_id | emp_id | version_no | name | email | department | salary | operation | changed_at | changed_by |
|-----------:|-------:|-----------:|------|-------|------------|-------:|-----------|------------|-----------:|
| 1 | 101 | 1 | Asha Rao | asha@corp.in | Sales | 50000 | INSERT | 2026-01-05 10:00 | 1 |
| 2 | 102 | 1 | Vikram Shah | vikram@corp.in | IT | 70000 | INSERT | 2026-01-05 10:05 | 1 |
| 3 | 101 | 2 | Asha Rao | asha@corp.in | Sales | 60000 | UPDATE | 2026-03-01 09:30 | 2 |
| 4 | 102 | 2 | Vikram Shah | vikram@corp.in | IT | 0 | UPDATE | 2026-04-10 17:02 | 2 |

We add a simple surrogate key `history_id` so each version is easy to refer to (for example in a restore). `(emp_id, version_no)` stays a candidate key (UNIQUE).

---

## 4. Boyce–Codd Normal Form (BCNF)

**Rule:** for every functional dependency `X → Y`, `X` must be a key.

| Table | Functional dependencies | Every determinant is a key? | BCNF? |
|-------|------------------------|-----------------------------|-------|
| users | `user_id → username, role`; `username → user_id, role` | `user_id` is the PK, `username` is UNIQUE | Yes |
| employees | `emp_id → name, email, department, salary`; `email → emp_id, …` | `emp_id` is the PK, `email` is UNIQUE | Yes |
| employees_history | `history_id → all`; `(emp_id, version_no) → all` | both are keys | Yes |

All three tables are in **BCNF**.

---

## 5. Why not just add an `old_salary` column?

A tempting shortcut is to add `old_salary` to `employees`. It fails:

| Problem | What goes wrong |
|---------|-----------------|
| Only one step back | After two updates, the first old value is overwritten. You cannot go back further. |
| Only one column | Changes to `name`, `email` or `department` are not saved at all. You would need `old_name`, `old_email` … for every column. |
| No "as of" | You cannot answer "what did the table look like at 5 PM yesterday?" |
| No "who" or "when" | Nothing records who made the change or when. |
| DELETE loses everything | When the row is deleted, `old_salary` is deleted with it, so the mistake cannot be undone. |
| Breaks normal form | `old_salary` is a value of a *different version* stored in the current row: a repeating group squeezed into a column. |

Storing every version as its own row in `employees_history` solves all of these.

---

## 6. Final design (3 tables)

```
users (user_id PK, username UNIQUE, role)                       role ∈ {admin, editor, viewer}

employees (emp_id PK, name, email UNIQUE, department, salary)    the live table

employees_history (history_id PK,
                   emp_id, version_no,                           UNIQUE (emp_id, version_no)
                   name, email, department, salary,              full copy of the row
                   operation,                                    INSERT / UPDATE / DELETE
                   changed_at,                                   when
                   changed_by → users.user_id)                   who
```

Relationships: one user makes many history rows (1 : N). One employee has many history rows (1 : N); this link is kept by `emp_id` but without a foreign key, so history survives a DELETE.
