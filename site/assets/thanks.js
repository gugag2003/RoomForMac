/* The thanks page: turns "?checkout_id=<id>" into the link that opens RoomForMac.
   Nothing here sends anything anywhere, stores anything or shows the id.

   roomForMacDeepLink is a pure function, so scripts/tests/site.bats runs it with
   osascript -l JavaScript. Its rules mirror RoomForMac/App/DeepLink.swift
   (DeepLink.parse): exactly one parameter, named checkout_id, whose value is 1 to
   128 ASCII letters, digits, "_" or "-". A page rule can only be stricter than the
   app's: this function never decodes "%" escapes, so it refuses what the app would
   decode. The constants below are checked against DeepLink.swift by site.bats. */

var ROOMFORMAC_LINK_SCHEME = 'roomformac';
var ROOMFORMAC_LINK_HOST = 'purchased';
var ROOMFORMAC_LINK_PARAMETER = 'checkout_id';
var ROOMFORMAC_CHECKOUT_ID_MAX = 128;

// "?checkout_id=<id>" -> "roomformac://purchased?checkout_id=<id>", or null.
function roomForMacDeepLink(search) {
    if (typeof search !== 'string' || search.charAt(0) !== '?') {
        return null;
    }
    var pairs = search.slice(1).split('&');
    if (pairs.length !== 1) {
        return null;
    }
    var prefix = ROOMFORMAC_LINK_PARAMETER + '=';
    if (pairs[0].indexOf(prefix) !== 0) {
        return null;
    }
    var id = pairs[0].slice(prefix.length);
    if (id.length < 1 || id.length > ROOMFORMAC_CHECKOUT_ID_MAX) {
        return null;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(id)) {
        return null;
    }
    return ROOMFORMAC_LINK_SCHEME + '://' + ROOMFORMAC_LINK_HOST + '?' + prefix + id;
}

(function () {
    if (typeof document === 'undefined') {
        return; // Not a browser: the tests load this file to call the function above.
    }
    var link = roomForMacDeepLink(window.location.search);
    var button = document.getElementById('open-app');
    var opening = document.getElementById('open-status');
    var unreadable = document.getElementById('link-unreadable');
    if (link === null) {
        if (unreadable !== null) {
            unreadable.hidden = false;
        }
        return;
    }
    if (button !== null) {
        button.setAttribute('href', link);
        button.hidden = false;
    }
    if (opening !== null) {
        opening.hidden = false;
    }
    // One attempt. Chrome ignores a custom-scheme launch that has no user gesture,
    // and no browser says whether an app answered, so the button stays as well.
    window.setTimeout(function () {
        window.location.href = link;
    }, 600);
})();
