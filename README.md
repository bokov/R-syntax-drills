# Rolling `learnr` syntax drills with automatic scoring and Google Sheets logging

This project provides browser-based R syntax drills using:

- `learnr` for interactive exercises;
- `gradethis` for immediate automatic scoring;
- a Google Apps Script web app for append-only event logging and a persistent rolling question queue;
- Google Sheets as the authoritative assignment/event store;
- an instructor-side cumulative drill report;
- `rsconnect` for deployment to shinyapps.io.

The canonical question bank lives under `question-bank/`. `index.Rmd` is the stable player. Students do not receive a hand-curated weekly assignment: each student has an active queue that evolves one question at a time as questions are answered correctly.

## 1. Install packages

```r
source("scripts/01_install_packages.R")
```

## 2. Create or update the Google service

For a new spreadsheet:

1. Create a private Google Sheet.
2. Open **Extensions > Apps Script**.
3. Replace the generated `Code.gs` with `google-apps-script/Code.gs` from this repository.
4. If you can edit the Apps Script manifest, replace it with `google-apps-script/appsscript.json`; otherwise the default manifest is sufficient.
5. Run `setupGradeSheet()` once and approve the requested permission. It creates/verifies `events`, `assignments`, `question_bank`, and `reviews` without erasing existing history.
6. Choose **Deploy > New deployment > Web app**.
7. Set **Execute as** to yourself and permit **Anyone** if your Workspace policy allows it.
8. Deploy and copy the production URL ending in `/exec`.
9. Copy the Google Sheet ID from the Sheet URL.

When `Code.gs` changes, copy/save the new source and deploy a **new version** of the existing web-app deployment. Run `setupGradeSheet()` again only when the change explicitly requires a persistent schema migration. Keep the same `/exec` URL unless Google gives you a different one.

The Sheet still contains historical `week_id` columns from the earlier weekly design. They are retained as provenance for existing rows; the rolling runtime no longer sends or depends on `week_id`, so new rows leave those cells blank.

## 3. Configure the rolling queue

The real `R/app_config.R` is ignored by Git. Start from `R/app_config_example.R`:

```r
APP_CONFIG <- list(
  course_id = "R101",
  app_name = "r-syntax-drills",
  queue_size = 10L,
  topic_priority = c(
    "vector_creation",
    "vector_indexing"
  ),
  google_sheet_id = "YOUR_SHEET_ID",
  webhook_url = "YOUR_APPS_SCRIPT_EXEC_URL",
  deadline_utc = NA_character_
)
```

### `queue_size`

The number of questions kept active for each student. A correct answer retires one assignment exposure and creates one replacement so the queue returns to this size. An incorrect answer leaves the question active.

The first curriculum topic must contain at least `queue_size` distinct scored exercises. Its `starter_question=TRUE` set must contain at least one question and no more than `queue_size` questions.

### `topic_priority`

An ordered curriculum from earliest to most advanced topic. Topic names must exactly match canonical question metadata. Keep previously introduced topics in the list: removing a topic that already appears in a student's history would make that student's curriculum state ambiguous.

This list is not merely an allow-list. Its order defines the curriculum frontier used by progression.

### `app_name`

Keep this stable so `rsconnect` updates the same shinyapps.io application and student URL.

### Starter questions

Mark starter exercises in their canonical chunk metadata:

````text
```{r vector_c01c, exercise=TRUE, topic="vector_creation", starter_question=TRUE}
```
````

On first use, the queue is filled entirely from the first curriculum topic. Starter questions are included first; remaining slots use least-exposed questions from that same topic.

## 4. Sync and publish

After editing `R/app_config.R` and/or the canonical question bank, the normal instructor workflow is:

```r
source("scripts/08_publish.R")
```

That command:

1. rebuilds and validates the canonical question-bank manifest;
2. validates `queue_size`, `topic_priority`, and starter availability;
3. synchronizes safe question metadata to the private Google `question_bank` tab;
4. builds `runtime_question_pool.Rmd` and `question_manifest.csv`;
5. deploys/updates the stable `index.Rmd` player on shinyapps.io.

There is no weekly publish boundary and no generated week-specific player.

To sync metadata without deploying:

```r
source("scripts/06_sync_question_bank.R")
```

To deploy after metadata are already synchronized:

```r
source("scripts/03_deploy_shinyapps.R")
```

## 5. How rolling selection works

A canonical **topic is one scheduling/memory unit**. Literal questions carrying that topic are interchangeable retrieval probes of the same skill.

When a valid student ID is saved:

1. Existing active assignments for `(course_id, student_id)` are returned oldest-to-newest.
2. A new student receives a full queue from the first curriculum topic, including every configured starter question.
3. Each assignment exposure contributes exactly one first-attempt observation to mastery and FSRS state. First-attempt correct is **Good**; first-attempt incorrect is **Again**. Retries do not create additional FSRS reviews.
4. A topic is mastered only after at least 10 first-attempt observations and at least 9 correct among the most recent 10.
5. Once a topic has been introduced, it remains introduced even if later performance drops below the mastery threshold.
6. When a question that was missed on its first attempt is eventually answered correctly, its replacement is drawn from the same topic.
7. Otherwise, introduced topics whose FSRS retrievability is below 0.90 are considered due first, lowest retrievability first.
8. If nothing introduced is due and the current curriculum frontier is mastered, the next topic is introduced.
9. Otherwise replacement practice remains at the current frontier (or another already introduced topic when necessary).
10. Within the selected topic, the least-used literal question is preferred; ties are randomized. Active labels are excluded.

A stale duplicate browser tab is intentionally tolerated. A wrong answer to a question already retired in another tab remains an extra retry on that old exposure; getting it correct (or refreshing) brings the tab back to the current authoritative queue without creating an extra replacement.

## 6. Run locally

```r
source("scripts/00_run_local.R")
```

This validates the bank/config, builds the generated question pool and manifest, and runs the same stable `index.Rmd` used for deployment.

The player uses `options(tutorial.storage = "none")`: exercise editors persist only for the current Shiny session. Google `events`, `assignments`, and `reviews` remain authoritative across sessions.

## 7. Testing

Run the R test suite:

```r
source("tests/testthat.R")
```

Test the basic logging endpoint:

```r
source("scripts/02_test_webhook.R")
```

Test the rolling assignment service after deploying the current Apps Script:

```r
source("scripts/07_test_assignment_service.R")
```

The service smoke test uses a fresh `INSTRUCTOR_ASSIGNMENT_TEST_*` ID and checks initial queue creation, stable reloads, wrong/correct retry behavior, replacement ordering, idempotent duplicate requests, curriculum routing, and final active-queue lookup. With timing diagnostics enabled it also reports Apps Script handler stages plus global-lock wait/hold time.

Smoke-test rows are deliberately retained as an audit trail.

## 8. Cumulative drill report

Optionally copy `roster.csv.example` to ignored `roster.csv`, then run:

```r
source("scripts/04_build_gradebook.R")
```

The report is cumulative for `APP_CONFIG$course_id`; it is no longer sliced by week. Historical and retired rolling exposures remain valid denominator rows, and repeated appearances of the same literal question remain distinct exposures because `assignment_id` is the exposure key.

The script writes:

- `output/grades.csv`
- `output/item_detail.csv`
- Google Sheet tab `grades`
- Google Sheet tab `detail`

The optional `deadline_utc` filters attempts after that UTC timestamp. These drill scores are reporting data; whether they contribute to a course grade is an instructor policy outside this code.

## 9. Canonical question authoring

Canonical questions live only under `question-bank/`. Question IDs (`item_label`) are permanent and globally unique. Do not reuse an existing ID for a substantially different literal question.

Use explicit boundaries:

```text
<!-- question: vector_c01c -->
## Question title

[prompt/setup/exercise/solution/checker]

<!-- /question -->
```

The marker ID must match the exercise/question chunk label. Canonical metadata include `topic`, `points`, and `starter_question`.

The generated runtime pool contains scored `exercise_result` questions but omits their `*-solution` chunks. The canonical question bank itself is not deployed. `question_bank_manifest.csv`, `question_manifest.csv`, and `runtime_question_pool.Rmd` are generated files and should not be edited or committed.

The old hand-curated Week 01 source remains under `examples/legacy_static_week01.Rmd` only as historical reference.

## Security / reliability notes

- `learnr` executes student-supplied R. Use hosting isolation appropriate to the stakes of the course.
- The Google Sheet remains private; the deployed app communicates only through the Apps Script web endpoint.
- Student IDs are self-asserted in this lightweight architecture. Assignment lookup is not authentication.
- A student who deliberately unhides an unassigned exercise in browser developer tools can see/run it, but it has no active matching `assignment_id` and does not become an assigned exposure.
- Assignment/event history in Google Sheets is authoritative; browser answer state is intentionally nonpersistent.
