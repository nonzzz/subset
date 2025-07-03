pub const Error = error{
    InvalidHeadTable,
    InvalidHheaTable,
    InvalidMaxpVersion,
    InvalidNameTableVersion,
    InvalidOs2Version,
    InvalidPostVersion,
    InvalidGlyfTable,
    DeprecatedPostVersion25,
    UnsupportedCmapFormat,

    MissingHheaTable,
    MissingMaxpTable,

    MissingHeadTable,
};
