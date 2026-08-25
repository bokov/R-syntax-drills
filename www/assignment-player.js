(function() {
  // Browser-side registration state prevents duplicate Shiny message handlers.
  var handlersRegistered = false;

  /**
   * Finds the status element that occupies the assignment area before drills
   * have been loaded and reports player errors.
   *
   * Called by assignmentTopic(), hideAll(), and showAssignments().
   * @returns {HTMLElement|null} The assignment waiting/status element.
   */
  function waitingElement() {
    return document.getElementById('assignment-waiting');
  }

  /**
   * Locates the learnr section containing the assignment exercises so DOM
   * searches stay scoped to the drill player.
   *
   * Called only by exerciseElements(); depends on waitingElement().
   * @returns {HTMLElement|Document} The assignment section, or document as a
   * fallback when the waiting element is unavailable.
   */
  function assignmentTopic() {
    var waiting = waitingElement();
    return waiting ? waiting.closest('.section.level2') : document;
  }

  /**
   * Returns every labeled learnr exercise element in the assignment section.
   *
   * Called by questionSectionForLabel() and allQuestionBlocks(); depends on
   * assignmentTopic().
   * @returns {HTMLElement[]} Labeled tutorial exercise elements.
   */
  function exerciseElements() {
    return Array.prototype.slice.call(
      assignmentTopic().querySelectorAll('.tutorial-exercise[data-label]')
    );
  }

  /**
   * Resolves an exercise to the native learnr question-section container and
   * tags that section for assignment-player styling.
   *
   * Called by questionSectionForLabel() and allQuestionBlocks().
   * @param {HTMLElement|null} exercise A learnr exercise element.
   * @returns {HTMLElement|null} The containing level-4 section, when present.
   */
  function questionSection(exercise) {
    if (!exercise) return null;

    // learnr's tutorial format uses Pandoc section divs and emits each exercise
    // as .tutorial-exercise[data-label=<chunk label>]. Each generated question
    // has a level-4 heading, so its nearest level-4 section is the native
    // container for the heading, prompt, and exercise.
    var section = exercise.closest('.section.level4');
    if (section) section.classList.add('assignment-question');
    return section;
  }

  /**
   * Finds the question section corresponding to one assignment item label.
   *
   * Called by showAssignments(); depends on exerciseElements() and
   * questionSection().
   * @param {string} label Item label to locate.
   * @returns {HTMLElement|null} The corresponding question section.
   */
  function questionSectionForLabel(label) {
    // The callback selects the rendered exercise whose data label matches.
    var exercise = exerciseElements().find(function(element) {
      return element.getAttribute('data-label') === label;
    });
    return questionSection(exercise);
  }

  /**
   * Collects each distinct question section represented by labeled exercises.
   *
   * Called by hideAll(); depends on exerciseElements() and questionSection().
   * @returns {HTMLElement[]} Distinct question-section elements.
   */
  function allQuestionBlocks() {
    var seen = [];
    // The callback resolves each exercise and retains each containing section once.
    exerciseElements().forEach(function(exercise) {
      var section = questionSection(exercise);
      if (section && seen.indexOf(section) < 0) seen.push(section);
    });
    return seen;
  }

  /**
   * Hides every assignment question and restores the initial waiting message.
   *
   * Called by showAssignments(), the `assignment:clear` Shiny handler, and once
   * during startup; depends on allQuestionBlocks() and waitingElement().
   * @returns {void}
   */
  function hideAll() {
    // Hide each native learnr question section.
    allQuestionBlocks().forEach(function(block) {
      block.style.display = 'none';
    });

    var waiting = waitingElement();
    if (waiting) {
      waiting.style.display = 'block';
      waiting.className = 'alert alert-info';
      waiting.textContent =
        'Your questions will appear here after you save a valid student ID.';
    }
  }

  /**
   * Reconciles visible question sections with the ordered item-label list sent
   * by Shiny, hiding unassigned questions and reordering assigned sections to
   * match the persisted queue order.
   *
   * Registered as the `assignment:set` custom message handler by
   * registerShinyHandlers(). Depends on hideAll(), questionSectionForLabel(),
   * and waitingElement().
   * @param {{item_labels?: string[]}|null} message Assignment message from Shiny.
   * @returns {void}
   */
  function showAssignments(message) {
    hideAll();

    var labels = (message && message.item_labels) || [];
    var shown = 0;
    var destination = null;

    // Reveal and position each assigned question in server-provided order.
    labels.forEach(function(label, index) {
      var block = questionSectionForLabel(label);
      if (!block) {
        console.error('Assigned question is missing from the player:', label);
        return;
      }

      if (!destination) destination = block.parentNode;
      if (destination && block.parentNode === destination) {
        // Re-appending native section divs preserves persisted assignment order
        // while all non-assigned question sections remain hidden.
        destination.appendChild(block);
      }

      block.style.display = 'block';
      block.dataset.assignmentOrder = String(index);
      shown += 1;
    });

    var waiting = waitingElement();
    if (waiting) {
      if (shown === labels.length && shown > 0) {
        waiting.style.display = 'none';
      } else if (labels.length > 0) {
        waiting.style.display = 'block';
        waiting.className = 'alert alert-danger';
        waiting.textContent =
          'Your assignment was created, but one or more assigned questions ' +
          'could not be found in this player. Rebuild the local player and reload.';
      } else {
        waiting.style.display = 'block';
      }
    }
  }

  /**
   * Registers the custom Shiny messages that set or clear the assignment player
   * after the browser-side Shiny API becomes available.
   *
   * Called by registerWhenReady() and its retry timer; depends on
   * showAssignments() and hideAll().
   * @returns {boolean} True once handlers are registered, false while Shiny is
   * not ready.
   */
  function registerShinyHandlers() {
    if (handlersRegistered) return true;
    if (!window.Shiny || !window.Shiny.addCustomMessageHandler) return false;

    window.Shiny.addCustomMessageHandler('assignment:set', showAssignments);
    // The clear-message callback hides every currently displayed assignment.
    window.Shiny.addCustomMessageHandler('assignment:clear', function(message) {
      hideAll();
    });
    handlersRegistered = true;
    return true;
  }

  /**
   * Registers Shiny handlers immediately when possible or polls briefly until
   * the Shiny client has initialized.
   *
   * Called once during script startup; depends on registerShinyHandlers().
   * @returns {void}
   */
  function registerWhenReady() {
    if (registerShinyHandlers()) return;

    var attempts = 0;
    // Retry registration until Shiny is ready or the fixed retry cap is reached.
    var timer = window.setInterval(function() {
      attempts += 1;
      if (registerShinyHandlers() || attempts >= 200) {
        window.clearInterval(timer);
      }
    }, 50);
  }

  // This script is inlined after runtime_question_pool.Rmd, so the rendered
  // question DOM already exists even if Shiny's browser object is not ready yet.
  hideAll();
  registerWhenReady();
})();
