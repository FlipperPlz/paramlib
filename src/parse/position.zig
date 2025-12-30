pub const SourcePosition = struct {
    index: usize,
    line: usize,
    line_start: usize,

    pub fn init(index: usize, line: usize, line_start: usize) SourcePosition {
        return .{
            .index = index,
            .line = line,
            .line_start = line_start,
        };
    }
};