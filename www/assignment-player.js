(function() {
  function allQuestionBlocks() {
    return Array.prototype.slice.call(
      document.querySelectorAll('.assignment-question')
    );
  }

  function hideAll() {
    allQuestionBlocks().forEach(function(block) {
      block.style.display = 'none';
    });

    var waiting = document.getElementById('assignment-waiting');
    if (waiting) waiting.style.display = 'block';
  }

  function showAssignments(message) {
    var pool = document.getElementById('assignment-question-pool');
    if (!pool) return;

    hideAll();

    var labels = (message && message.item_labels) || [];
    labels.forEach(function(label) {
      var block = document.getElementById('assignment-question-' + label);
      if (!block) return;

      // Re-appending places the visible questions in the persisted assignment
      // order without changing any learnr exercise IDs.
      pool.appendChild(block);
      block.style.display = 'block';
    });

    var waiting = document.getElementById('assignment-waiting');
    if (waiting) {
      waiting.style.display = labels.length ? 'none' : 'block';
    }
  }

  document.addEventListener('DOMContentLoaded', hideAll);

  if (window.Shiny) {
    Shiny.addCustomMessageHandler('assignment:set', showAssignments);
    Shiny.addCustomMessageHandler('assignment:clear', hideAll);
  }
})();
