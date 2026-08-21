// Read-only student progress reporting. This reuses the same mastery and FSRS
// calculations that drive adaptive scheduling; it does not maintain a second
// progress model.

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
