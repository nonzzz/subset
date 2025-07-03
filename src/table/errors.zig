pub const Error = error{
    InvalidHeadTable,
    InvalidHheaTable,
    InvalidMaxpVersion,
    InvalidNameTableVersion,
    InvalidOs2Version,
    InvalidPostVersion,
    InvalidGlyfTable,
    DeprecatedPostVersion25,

    MissingHheaTable,
    MissingMaxpTable,

    MissingHeadTable,
};
