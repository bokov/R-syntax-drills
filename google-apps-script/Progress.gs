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

function handleGetProgress(data, ss) {
  validateAssignmentRequest(data);
  const topicPriority = validateProgressTopics(data);
  const timer = startServiceTimer('get_progress', data.request_id);

  const reviewsSheet = ss.getSheetByName(REVIEW_SHEET);
  const questionBankSheet = ss.getSheetByName(QUESTION_BANK_SHEET);
  if (!reviewsSheet || !questionBankSheet) {
    throw new Error(
      'reviews and question_bank must exist. Run setupGradeSheet() after updating Code.gs.'
    );
  }

  let bankHandshake = null;
  if (requestUsesBankHandshake(data)) {
    bankHandshake = bankHandshakeForRequest(data, questionBankSheet);
    if (!bankHandshake.compatible) {
      return jsonResponse(bankHandshake.response);
    }
  }
  markServiceTimer(timer, 'sheets_ready');

  const asOf = new Date();
  const reviews = getReviewsForStudent(
    reviewsSheet,
    data.course_id,
    data.student_id
  );
  const progress = studentProgressSummary(reviews, topicPriority, asOf);
  markServiceTimer(timer, 'progress_computed');

  timer.result = 'reported';
  timer.review_count = reviews.length;
  const response = {
    ok: true,
    request_id: data.request_id,
    as_of_utc: asOf.toISOString(),
    progress: progress
  };
  attachBankVersion(response, bankHandshake);
  markServiceTimer(timer, 'response_ready');
  if (includeServiceTiming(data)) {
    response.service_timing = serviceTimerSnapshot(timer);
  }
  logServiceTimer(timer);
  return jsonResponse(response);
}
