# 🛠️ Global Odoo Development Guidelines

These instructions apply to **ALL** code suggestions in this repository. Copilot must prioritize Odoo's ORM and framework conventions over generic Python patterns.

---

## 🧠 General Principles

- **Prioritize ORM:** Use the Odoo ORM over raw SQL unless strictly necessary for extreme performance cases.
- **Maintainability:** Write clear, modular code aligned with Odoo's official coding standards.
- **Modularity:** Prefer extending existing models and views rather than creating redundant logic.
- **Version Agnostic:** Use standard API patterns that are consistent across Odoo versions (avoid deprecated methods).

---

## 🐍 Python & ORM Usage

- **Recordsets & Batching:**
  - Use vectorized operations. Avoid iterating over recordsets (`for record in self`) if a batch operation exists.
  - Use `mapped()`, `filtered()`, and `sorted()` instead of Python loops.
- **Inheritance & `@api.depends`:**
  - **Cumulative Dependencies:** When overriding a compute method or extending a field, do **NOT** rewrite existing dependencies. Odoo merges them automatically from the parent classes. Only declare the **new** fields your specific logic requires.
- **Performance:**
  - **Strictly Avoid N+1 queries.** Never execute `search()`, `browse()`, or `read()` inside a loop.
  - Prefer `read_group()` for aggregations.
- **Domains:** Always use precise domains in `search()` to limit results at the database level.
- **Computed Fields:** Avoid unnecessary `store=True` unless the field is used for searching or grouping.

---

## 🖼️ XML & View Architecture

- **Clean Inheritance:**
  - Use `xpath` with the most specific attributes. Prefer `name` over `expr` or positional indices (`position="after"`).
- **Naming Conventions:** Use clear IDs following the pattern: `model_name_view_type` (e.g., `sale_order_view_form`).
- **Structure:** Follow the standard XML order:
  1. Security/Data (`ir.model.access.csv`, `data.xml`).
  2. Actions & Window Actions.
  3. Menu Items.
  4. Views (Tree, Form, Search, etc.).

---

## 🏢 Multi-company & Security

- **Multi-company Awareness:**
  - Always respect `company_id` and `company_ids`.
  - Use `self.env.company` for current context and ensure searches filter by company when applicable.
- **Security First:**
  - **Avoid `sudo()`:** Never bypass access rules unless it is a documented technical requirement.
  - **Data Integrity:** Always include `ir.model.access.csv` for new models.

---

## 🌍 Localization & UX

- **Translatable Strings:** Always wrap user-facing strings in Python with `_()`.
- **Labels & Help:** Every field should have a clear `string` and, where necessary, a `help` attribute to assist the user.
- **Logging:** Use `_logger.info()` or `_logger.warning()` instead of `print()`.

---

## 🚫 Anti-patterns to Avoid

- **Raw SQL:** Prohibited unless explicitly justified and sanitized.
- **Queries in Loops:** A critical performance failure.
- **Hardcoded IDs:** Never use database IDs. Always use XML IDs via `self.env.ref()`.
- **Ignoring `super()`:** Always call `super()` when extending standard methods (`create`, `write`, `unlink`) to maintain the execution chain.
- **Logic in Views:** Keep business logic in Python models, not in XML or JS templates.

---

## ✅ Expected Output Quality

1. **Production-Ready:** Code must be safe for enterprise environments.
2. **Standard-Compliant:** Strictly follow Odoo's official "Coding Guidelines".
3. **Optimized:** Performance and multi-company context must be considered by default.