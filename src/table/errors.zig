pub const Error = error{
    InvalidHeadTable,
    InvalidHheaTable,
    InvalidMaxpVersion,
    InvalidNameTableVersion,
    InvalidOs2Version,
    InvalidPostVersion,
    DeprecatedPostVersion25,

    MissingHheaTable,
    MissingMaxpTable,

    MissingHeadTable,
};
