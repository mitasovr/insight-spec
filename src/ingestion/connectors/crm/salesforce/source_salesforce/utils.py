"""Miscellaneous helpers."""


_CRITERIA_MAPPING = {
    "starts with": lambda stream_name, word: stream_name.startswith(word),
    "starts not with": lambda stream_name, word: not stream_name.startswith(word),
    "ends with": lambda stream_name, word: stream_name.endswith(word),
    "ends not with": lambda stream_name, word: not stream_name.endswith(word),
    "contains": lambda stream_name, word: word in stream_name,
    "not contains": lambda stream_name, word: word not in stream_name,
    "exacts": lambda stream_name, word: word == stream_name,
    "not exacts": lambda stream_name, word: word != stream_name,
}


def filter_streams_by_criteria(streams_list: list, search_word: str, search_criteria: str) -> list:
    """Filter ``streams_list`` by a human-readable criterion.

    Valid ``search_criteria`` values: see ``_CRITERIA_MAPPING`` keys. Unknown
    criteria produce an empty result instead of raising ``KeyError`` so an
    operator typo doesn't break the whole stream discovery.
    """
    predicate = _CRITERIA_MAPPING.get(search_criteria)
    if predicate is None:
        return []
    word = search_word.lower()
    return [stream for stream in streams_list if predicate(stream.lower(), word)]
