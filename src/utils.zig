const std = @import("std");

const ipld = @import("ipld");
const Kind = ipld.Kind;

pub fn getRepresentation(comptime T: type, comptime decls: []const std.builtin.Type.Declaration) ?Kind {
    inline for (decls) |decl| {
        if (comptime std.mem.eql(u8, decl.name, "IpldKind")) {
            if (@TypeOf(T.IpldKind) != Kind)
                @compileError("expcted declaration T.IpldKind to be a ipld.Kind");

            return T.IpldKind;
        }
    }

    return null;
}
