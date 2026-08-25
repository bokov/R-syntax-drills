// Read-only student progress reporting. This reuses the same mastery and FSRS
// calculations that drive adaptive scheduling; it does not maintain a second
// progress model.

// Progress request validation -------------------------------------------------

/**
 * Validates and normalizes the ordered curriculum topics supplied by a progress
 * request so the report uses the same curriculum vocabulary as scheduling.
 *
 * Called only by progressPayloadForRequest(). It has no within-file helper
 * dependencies.
 *
 * @param {Object} data Parsed request payload containing topic_priority.
 * @return {string[]} Trimmed curriculum topics in request order.
 * @throws {Error} If topic_priority is missing, empty, duplicated, or invalid.
 */
function validateProgressTopics(data) {
  if (!Array.isArray(data.topic_priority) || !data.topic_priority.length) {
    throw new Error('topic_priority must be a non-empty ordered array.');
  }

  const topics = data.topic_priority.map(function(value) {
    return String(value).trim();
  });
  if (topics.some(function(topic) { return !topic || topic.length > 300; })) {
    throw new Error('Each curriculum topic must be a non-empty string of at most 300 characters.');
  }
  if (new Set(topics).size !== topics.length) {
    throw new Error('topic_priority must not contain duplicates.');
  }
  return topics;
}

// Progress summary construction ----------------------------------------------

/**
 * Builds one student-facing progress row per curriculum topic from persisted
 * review history, combining mastery-window statistics with current FSRS recall.
 *
 * Called only by progressPayloadForRequest(). Depends on
 * topicRetrievabilitiesFromReviews() and topicMasterySummary() in Code.gs.
 *
 * @param {Object[]} reviews Compact review objects for one student.
 * @param {string[]} topicPriority Ordered curriculum topics to report.
 * @param {Date} asOf Time at which estimated retrievability is calculated.
 * @return {Object[]} Progress rows with practice counts, accuracy, recall, and
 * mastery state for each topic.
 */
function studentProgressSummary(reviews, topicPriority, asOf) {
  const retrievability = topicRetrievabilitiesFromReviews(
    reviews,
    topicPriority,
    asOf
  );

  return topicPriority.map(function(topic) {
    const mastery = topicMasterySummary(reviews, topic);
    return {
      topic: topic,
      observations: mastery.observations,
      recent_count: mastery.recent_count,
      recent_correct: mastery.recent_correct,
      recent_accuracy: mastery.recent_accuracy,
      estimated_recall: mastery.observations
        ? retrievability[topic]
        : null,
      mastered: mastery.mastered
    };
  });
}

/**
 * Builds the optional progress portion of an assignment-service response by
 * loading this student's reviews and summarizing them at the current time.
 *
 * Called by bankReconciliationForRequest() in BankReconciliation.gs when
 * include_progress is true. Depends on validateProgressTopics(),
 * getReviewsForStudent() in Code.gs, studentProgressSummary(), and REVIEW_SHEET.
 *
 * @param {Object} data Parsed service request.
 * @param {GoogleAppsScript.Spreadsheet.Sheet} questionBankSheet Question-bank
 * sheet used to locate the containing spreadsheet.
 * @return {?Object} Null when progress was not requested; otherwise an object
 * containing as_of_utc and progress rows.
 * @throws {Error} If progress was requested but the reviews sheet is missing or
 * the request topics are invalid.
 */
function progressPayloadForRequest(data, questionBankSheet) {
  if (!data || data.include_progress !== true) return null;

  const topicPriority = validateProgressTopics(data);
  const spreadsheet = questionBankSheet.getParent();
  const reviewsSheet = spreadsheet.getSheetByName(REVIEW_SHEET);
  if (!reviewsSheet) {
    throw new Error(
      'The reviews sheet does not exist. Run setupGradeSheet() after updating Code.gs.'
    );
  }

  const asOf = new Date();
  const reviews = getReviewsForStudent(
    reviewsSheet,
    data.course_id,
    data.student_id
  );

  return {
    as_of_utc: asOf.toISOString(),
    rows: studentProgressSummary(reviews, topicPriority, asOf)
  };
}
