.pragma library

.import "LyricsHelpers.js" as LyricsHelpers

function timeoutSecondsValue(timeoutMs) {
  return Math.max(1, Math.ceil(Math.max(1000, Number(timeoutMs || 5000)) / 1000));
}

function buildSearchBody(keyword) {
  return JSON.stringify({
                          "comm": {
                            "ct": 19,
                            "cv": "1845",
                            "v": "1003006",
                            "os_ver": "12",
                            "phonetype": "0",
                            "devicelevel": "31",
                            "tmeAppID": "qqmusiclight",
                            "nettype": "NETWORK_WIFI"
                          },
                          "req": {
                            "module": "music.search.SearchCgiService",
                            "method": "DoSearchForQQMusicLite",
                            "param": {
                              "query": String(keyword || ""),
                              "search_type": 0,
                              "num_per_page": 50,
                              "page_num": 0,
                              "nqc_flag": 0,
                              "grp": 0
                            }
                          }
                        });
}

function buildSearchCommand(keyword, timeoutMs) {
  var timeoutSeconds = timeoutSecondsValue(timeoutMs);
  return [
    "curl",
    "-sS",
    "--max-time",
    String(timeoutSeconds),
    "https://u.y.qq.com/cgi-bin/musicu.fcg",
    "-H",
    "Accept: application/json",
    "-H",
    "Content-Type: application/json",
    "-H",
    "User-Agent: Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)",
    "--data-raw",
    buildSearchBody(keyword)
  ];
}

function buildLyricCommand(mid, timeoutMs) {
  var params = {
    songmid: mid,
    g_tk: "5381",
    format: "json",
    inCharset: "utf8",
    outCharset: "utf-8",
    nobase64: "1"
  };
  var timeoutSeconds = timeoutSecondsValue(timeoutMs);
  var url = "https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?" + LyricsHelpers.buildQuery(params);
  return [
    "curl",
    "-sS",
    "--max-time",
    String(timeoutSeconds),
    url,
    "-H",
    "Accept: application/json",
    "-H",
    "Referer: https://y.qq.com"
  ];
}

function parseJsonResponseText(text) {
  var raw = String(text || "").trim();
  if (!raw) {
    return {
      "ok": false,
      "error": "empty response",
      "data": null
    };
  }

  var payload = null;
  try {
    payload = JSON.parse(raw);
  } catch (error) {
    return {
      "ok": false,
      "error": String(error),
      "data": null
    };
  }

  return {
    "ok": true,
    "error": "",
    "data": payload
  };
}

function parseSearchResponseText(text) {
  var parsed = parseJsonResponseText(text);
  if (!parsed.ok)
    return parsed;

  var payload = parsed.data || {};
  var topLevelCode = Number(payload.code !== undefined ? payload.code : 0);
  var requestPayload = payload.req || {};
  var requestCode = Number(requestPayload.code !== undefined ? requestPayload.code : 0);

  if (topLevelCode !== 0 || requestCode !== 0) {
    return {
      "ok": false,
      "error": "qqmusic search error code=" + topLevelCode + " reqCode=" + requestCode,
      "data": payload
    };
  }

  return {
    "ok": true,
    "error": "",
    "data": payload
  };
}

function parseLyricResponseText(text) {
  var parsed = parseJsonResponseText(text);
  if (!parsed.ok) {
    return {
      "ok": false,
      "lyric": "",
      "error": parsed.error,
      "data": null
    };
  }

  var payload = parsed.data || {};
  var code = Number(payload.code !== undefined ? payload.code : 0);
  var retcode = Number(payload.retcode !== undefined ? payload.retcode : 0);
  var subcode = Number(payload.subcode !== undefined ? payload.subcode : 0);
  if (code !== 0 || retcode !== 0 || subcode !== 0) {
    return {
      "ok": false,
      "lyric": "",
      "error": "qqmusic provider error code=" + code + " retcode=" + retcode + " subcode=" + subcode,
      "data": payload
    };
  }

  var lyric = payload.lyric !== undefined && payload.lyric !== null ? String(payload.lyric) : "";
  if (!lyric) {
    return {
      "ok": false,
      "lyric": "",
      "error": "qqmusic lyric missing",
      "data": payload
    };
  }

  return {
    "ok": true,
    "lyric": lyric,
    "error": "",
    "data": payload
  };
}

function buildCommand(mid, timeoutMs) {
  return buildLyricCommand(mid, timeoutMs);
}

function parseResponseText(text) {
  return parseLyricResponseText(text);
}
