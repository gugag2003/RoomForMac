/* The download page: shows the version, size and SHA-256 of the current release.
   The Download button does not need this file: its address is fixed in the page.
   The only request is for latest.json on this same site, which release.yml and
   pages.yml stage from the release summary. Nothing is stored, and nothing is sent
   apart from that request. */

// A release summary (schema 1, Task 11) -> { version, megabytes, sha256 }, or null
// when it is not one. Every field is checked, because the page shows them.
function roomForMacDownloadDetails(summary) {
    if (summary === null || typeof summary !== 'object' || summary.schema !== 1) {
        return null;
    }
    var dmg = summary.dmg;
    if (dmg === null || typeof dmg !== 'object') {
        return null;
    }
    if (typeof summary.version !== 'string' || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(summary.version)) {
        return null;
    }
    if (typeof dmg.size !== 'number' || !isFinite(dmg.size) || dmg.size <= 0 || Math.floor(dmg.size) !== dmg.size) {
        return null;
    }
    if (typeof dmg.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(dmg.sha256)) {
        return null;
    }
    return {
        version: summary.version,
        megabytes: (dmg.size / 1000000).toFixed(1),
        sha256: dmg.sha256
    };
}

(function () {
    if (typeof document === 'undefined' || typeof window.fetch !== 'function') {
        return; // Not a browser: the tests load this file to call the function above.
    }
    var details = document.getElementById('download-details');
    var version = document.getElementById('download-version');
    var checksum = document.getElementById('download-sha256');
    if (details === null || version === null || checksum === null) {
        return;
    }
    window.fetch('latest.json', { cache: 'no-cache' })
        .then(function (response) {
            return response.ok ? response.json() : null;
        })
        .then(function (summary) {
            var info = roomForMacDownloadDetails(summary);
            if (info === null) {
                return;
            }
            version.textContent = 'Version ' + info.version + ' · ' + info.megabytes + ' MB';
            checksum.textContent = info.sha256;
            details.hidden = false;
        })
        .catch(function () {
            // No summary yet, or offline: the button alone is enough.
        });
})();
