// Find CoreAnimation's Metal shader-specialization code: strings such as
// "fixed_vert_lph_spc"/"fc_vertex_layout" are referenced by the code that
// picks the vertex layout and sets the function constants. Decompile the
// referencing functions so the layout/stride table can be read off.
//@category vmios
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.Data;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.Reference;

public class FindCAVertexLayout extends GhidraScript {
    static final String[] WANT = {
        "fixed_vert_lph_spc", "fixed_vert_lph_gen", "fixed_frag_lph_cpf",
        "fc_vertex_layout", "fc_texcoord_count", "_lph"
    };

    @Override
    public void run() throws Exception {
        DecompInterface di = new DecompInterface();
        di.toggleCCode(true);
        di.openProgram(currentProgram);
        Listing listing = currentProgram.getListing();
        int found = 0;
        for (Data d : listing.getDefinedData(true)) {
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            boolean hit = false;
            for (String w : WANT) if (s.contains(w)) { hit = true; break; }
            if (!hit) continue;
            println("=== STRING 0x" + d.getAddress() + " = " + s);
            for (Reference r : getReferencesTo(d.getAddress())) {
                Address from = r.getFromAddress();
                Function f = listing.getFunctionContaining(from);
                if (f == null) {
                    println("  ref from 0x" + from + " (no function)");
                    continue;
                }
                println("  ref from 0x" + from + " in " + f.getName() + " @0x" + f.getEntryPoint());
                if (found++ >= 24) continue;
                DecompileResults res = di.decompileFunction(f, 90, monitor);
                if (res != null && res.decompileCompleted()) {
                    String c = res.getDecompiledFunction().getC();
                    println("--- DECOMP " + f.getName() + " ---");
                    println(c.length() > 30000 ? c.substring(0, 30000) : c);
                }
            }
        }
        println("=== done, functions=" + found);
        di.dispose();
    }
}
