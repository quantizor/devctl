/** Wraps `@changesets/changelog-github`, omitting self-thanks for the
    maintainer login while still thanking other contributors. */
const github = require("@changesets/changelog-github").default;

const NO_THANKS = new Set(["quantizor"]);

/** @param {string} line */
function stripMaintainerThanks(line) {
  return line.replace(
    / Thanks ((?:\[@[^\]]+\]\([^)]+\))(?:, (?:\[@[^\]]+\]\([^)]+\)))*)!/g,
    (_, users) => {
      const kept = users
        .split(/,\s*/)
        .filter((user) => {
          const match = user.match(/^\[@([^\]]+)\]/);
          return match ? !NO_THANKS.has(match[1].toLowerCase()) : true;
        });
      if (kept.length === 0) return "";
      return ` Thanks ${kept.join(", ")}!`;
    },
  );
}

module.exports = {
  getDependencyReleaseLine: github.getDependencyReleaseLine,
  getReleaseLine: async (changeset, type, options) => {
    const line = await github.getReleaseLine(changeset, type, options);
    return stripMaintainerThanks(line);
  },
};
