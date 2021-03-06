/*
    This file is part of BioD.
    Copyright (C) 2012    Artem Tarasov <lomereiter@gmail.com>

    BioD is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    BioD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

*/

import bio.sam.reader;
import bio.sam.header;
import bio.core.bgzf.blockrange;
import bio.bam.reader;
import bio.bam.writer;
import bio.bam.md.reconstruct;
import bio.bam.pileup;
import bio.bam.baseinfo;
import bio.bam.validation.samheader;
import bio.bam.validation.alignment;
import bio.bam.utils.samheadermerger;
import bio.sam.utils.recordparser;
import bio.bam.serialization.sam;
import bio.core.bgzf.outputstream;
import bio.core.utils.roundbuf;
import bio.core.utils.range;
import bio.core.utils.tmpfile;
import bio.core.utils.stream;
import bio.core.sequence;
import bio.core.base;
import bio.core.tinymap;
import bio.core.utils.roundbuf;

import std.path;
import std.range;
import std.stdio;
import std.stream;
import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.math;
import std.typetuple;

unittest {

    writeln("Testing extracting SAM header...");
    auto fn = buildPath(dirName(__FILE__), "data", "ex1_header.bam");
    auto bf = new BamReader(fn);
    assert(bf.header.format_version == "1.3");
    assert(bf.header.sorting_order == SortingOrder.coordinate);
    assert(bf.header.sequences.length == 2);
    assert(bf.header.getSequenceIndex("chr1") == 0);
    assert(bf.header.sequences["chr2"].length == 1584);

    fn = buildPath(dirName(__FILE__), "data", "bins.bam");
    bf = new BamReader(fn);
    assert(bf.header.sorting_order == SortingOrder.unknown);
    assert(bf.header.sequences.length == 3);
    assert(bf.header.read_groups.length == 0);
    assert(bf.header.getSequenceIndex("large") == 2);
    assert(bf.header.sequences["small"].length == 65536);

    {
    writeln("Testing alignment parsing...");
    fn = buildPath(dirName(__FILE__), "data", "ex1_header.bam");
    bf = new BamReader(fn);
    auto reads = bf.reads;
    auto read = reads.front;
    assert(equal(read.sequence, "CTCAAGGTTGTTGCAAGGGGGTCTATGTGAACAAA"));
    assert(equal(map!"cast(char)(a + 33)"(read.base_qualities),
                "<<<7<<<;<<<<<<<<8;;<7;4<;<;;;;;94<;"));
    assert(bf.reference(read.ref_id).name == "chr1");
    assert(read.name == "EAS56_57:6:190:289:82");
    assert(read.flag == 69);
    assert(read.position == 99);
    assert(read.mapping_quality == 0);
    reads.popFront();
    reads.popFront();
    assert(reads.front.cigarString() == "35M");
    assert(toSam(reads.front, bf.reference_sequences) == "EAS51_64:3:190:727:308	99	chr1	103	99	35M	=	263	195	GGTGCAGAGCCGAGTCACGGGGTTGCCAGCACAGG	<<<<<<<<<<<<<<<<<<<<<<<<<<<::<<<844	MF:i:18	Aq:i:73	NM:i:0	UQ:i:0	H0:i:1	H1:i:0");
    assert(bf.header.getSequenceIndex("chr1") == read.ref_id);
    }

    assert(bf.reads.front.name == "EAS56_57:6:190:289:82");

    writeln("Testing tag parsing...");
    fn = buildPath(dirName(__FILE__), "data", "tags.bam");
    bf = new BamReader(fn);
    foreach (alignment; bf.reads) {
        auto name = alignment.name;
        assert(name[0..4] == "tag_");
        char[] tag;
        name = name[4..$];
        while (name[0] != ':') {
            tag ~= name[0];
            name = name[1..$];
        }
        name = name[1..$];
        string value = toSam(alignment[tag.idup]);
        if (name != value) {
            writeln("tag: ", tag, "\tname: ", name, "\tvalue: ", value);
            writeln("value bam_typeid: ", alignment[tag.idup].bam_typeid);
        }

        assert(name == value);
    }

    writeln("Testing exception handling...");
    fn = buildPath(dirName(__FILE__), "data", "duplicated_block_size.bam");
    assertThrown!BgzfException(new BamReader(fn));
    fn = buildPath(dirName(__FILE__), "data", "no_block_size.bam");
    assertThrown!BgzfException(new BamReader(fn));
    fn = buildPath(dirName(__FILE__), "data", "wrong_extra_gzip_length.bam");
    assertThrown!BgzfException(new BamReader(fn));
    fn = buildPath(dirName(__FILE__), "data", "wrong_bc_subfield_length.bam");
    assertThrown!BgzfException(reduce!"a+b.sequence_length"(0, (new BamReader(fn)).reads!withoutOffsets));
    fn = buildPath(dirName(__FILE__), "data", "corrupted_zlib_archive.bam");
    assertThrown!ZlibException(walkLength((new BamReader(fn)).reads));

    writeln("Testing random access...");
    fn = buildPath(dirName(__FILE__), "data", "bins.bam");
    bf = new BamReader(fn);

    void compareWithNaiveApproach(int beg, int end) {

        auto refseq = array(bf["large"][beg .. end]);

        auto naive = array(filter!((BamRead a) { 
                         return a.ref_id != -1 &&
                                bf.reference(a.ref_id).name == "large" &&
                                a.position < end &&
                                a.position + a.basesCovered() > beg; })
                            (bf.reads!withoutOffsets));
        if (!equal(naive, refseq)) {
            writeln(beg);
            writeln(end);
            writeln(array(map!"a.name"(refseq)));
            writeln(array(map!"a.name"(naive)));
        }
        assert(equal(refseq, naive));
    }

    compareWithNaiveApproach(1400, 1500);
    compareWithNaiveApproach(  10,  123);
    compareWithNaiveApproach( 135, 1236);
    compareWithNaiveApproach(1350, 3612);
    compareWithNaiveApproach( 643, 1732);
    compareWithNaiveApproach( 267, 1463);
    compareWithNaiveApproach(   0,   30);
    compareWithNaiveApproach(1363, 1612);
    compareWithNaiveApproach( 361, 1231);
    compareWithNaiveApproach( 322,  612);
    compareWithNaiveApproach( 912,  938);
    compareWithNaiveApproach(   0, 3000);
    compareWithNaiveApproach(   0,  100);
    compareWithNaiveApproach(   0, 1000);
    compareWithNaiveApproach(   0, 1900);
    compareWithNaiveApproach(   1,  279);
    for (auto i = 50_000; i < 1_000_000; i += 50_000) {
        compareWithNaiveApproach(i, i + 100);
    }

    {
        auto fst_offset_tiny = bf["tiny"].startVirtualOffset();
        auto fst_offset_small = bf["small"].startVirtualOffset();
        auto fst_offset_large = bf["large"].startVirtualOffset();

        auto fst_read_tiny = bf.getReadAt(fst_offset_tiny);
        auto fst_read_small = bf.getReadAt(fst_offset_small);
        auto fst_read_large = bf.getReadAt(fst_offset_large);

        assert(fst_read_tiny.name == "tiny:r1:0..1:len1:bin4681:hexbin0x1249");
        assert(fst_read_small.name == "small:r1:0..1:len1:bin4681:hexbin0x1249");
        assert(fst_read_large.name == "large:r1:0..1:len1:bin4681:hexbin0x1249");
    }

    writeln("Testing Value code...");
    Value v = 5;
    assert(v.is_integer);
    assert(toSam(v) == "i:5");
    assert(v == 5);
    assert(v == "5");
    assert(v != [1,2,3]);
    v = "abc";
    assert(v.is_string);
    assert(toSam(v) == "Z:abc");
    assert(v == "abc");
    v = [1, 2, 3];
    assert(v.is_numeric_array);
    assert(toSam(v) == "B:i,1,2,3");
    assert(v == [1,2,3]);
    assert(v == "[1, 2, 3]");
    v = [1.5, 2.3, 17.0];
    assert(v.is_numeric_array);
    assert(toSam(v) == "B:f,1.5,2.3,17");
    assert(approxEqual(to!(float[])(v), [1.5, 2.3, 17]));
    v = 5.6;
    assert(v.is_float);
    assert(toSam(v) == "f:5.6");
    assert(approxEqual(to!float(v), 5.6));
    v = -17;
    assert(v.is_signed);
    assert(toSam(v) == "i:-17");
    assert(v == -17);
    assert(v == "-17");
    v = 297u;
    assert(v.is_unsigned);
    assert(toSam(v) == "i:297");
    assert(v == 297);
    assert(v == "297");

    short[] array_of_shorts = [4, 5, 6];
    v = array_of_shorts;
    assert(v.is_numeric_array);
    assert(toSam(v) == "B:s,4,5,6");
    assert(to!(short[])(v) == array_of_shorts);
    assert(v == [4,5,6]);
    assert(v == "[4, 5, 6]");

    v = null;
    assert(v.is_nothing);

    v = "0eabcf123";
    v.setHexadecimalFlag();
    assert(v.is_hexadecimal_string);    
    assert(v == "0eabcf123");

    writeln("Test parseAlignmentLine/toSam functions...");
    fn = buildPath(dirName(__FILE__), "data", "ex1_header.bam");
    bf = new BamReader(fn);
    foreach (read; bf.reads) {
        auto line = toSam(read, bf.reference_sequences);
        auto read2 = parseAlignmentLine(line, bf.header);
        if (read != read2) {
            writeln(read.name);
        }
        assert(read == read2);
    }

    fn = buildPath(dirName(__FILE__), "data", "tags.bam");
    bf = new BamReader(fn);
    foreach (read; bf.reads) {
        auto line = toSam(read, bf.reference_sequences);
        auto read2 = parseAlignmentLine(line, bf.header);
        if (read != read2 && isValid(read)) {
            writeln(read.name);
        }
        assert(read == read2 || !isValid(read));
    }

    writeln("Test BAM writing...");
    fn = buildPath(dirName(__FILE__), "data", "ex1_header.bam");
    bf = new BamReader(fn);
    {
    string tmp = tmpFile("12035913820619231129310.bam");
    auto stream = new bio.core.utils.stream.File(tmp, "wb+");

    auto writer = new BamWriter(stream);

    writer.writeSamHeader(bf.header);
    writer.writeReferenceSequenceInfo(bf.reference_sequences);

    foreach (read; bf.reads)
        writer.writeRecord(read);
    
    writer.flush();

    stream.seekSet(0);
    assert(walkLength((new BamReader(stream)).reads) == 3270);
    stream.close();
    }

    writeln("Test SAM reading...");
    {
    auto sf = new SamReader(buildPath(dirName(__FILE__), "data", "ex1_header.sam"));
    assert(sf.reads.front.ref_id == 0);
    assert(equal(sf.reads, bf.reads!withoutOffsets));
    }

    writeln("Testing pileup (high-level aspects)...");
    {
        // All of pileup functions should automatically filter out unmapped reads.

        // When reads in a range are aligned to different references,
        // pileup objects should process only the first one.
        bf = new BamReader(fn); // chr1, chr2
        {
            auto pileup = makePileup(bf.reads);
            foreach (column; pileup) {
                foreach (read; column.reads) {
                    assert(bf.reference_sequences[read.ref_id].name == "chr1");
                    assert(read.ref_id == column.ref_id);
                    assert(!read.is_unmapped);
                }
            }
        }
        // However, if pileupColumns is used, columns corresponding to chr1
        // should come first, and after them -- those for chr2
        {
            auto columns = pileupColumns(bf.reads);
            int current_ref_id = -1;

                                      // [99 .. 1569]   [1 .. 1567]
            int[2] expected_columns = [1470,            1567]; 
            foreach (column; columns) {
                int ref_id = column.ref_id;
                --expected_columns[ref_id];
                if (ref_id != current_ref_id) {
                    assert(ref_id > current_ref_id);
                    switch (ref_id) {
                        case 0:
                            assert(column.reads.front.name == "EAS56_57:6:190:289:82");
                            assert(column.position == 99);
                            break;
                        case 1:
                            assert(column.reads.front.name == "B7_591:8:4:841:340");
                            assert(column.position == 0);
                            break;
                        default:
                            break;
                    }

                    current_ref_id = ref_id;
                }
                if (!column.reads.empty) {
                    foreach (read; column.reads) {
                        assert(read.ref_id == ref_id);
                        assert(!read.is_unmapped);
                    }
                }
            }
            assert(expected_columns == [0, 0]);
        }
    }

    writeln("Testing basesWith functionality...");
    {
        fn = buildPath(dirName(__FILE__), "data", "mg1655_chunk.bam");
        bf = new BamReader(fn);
        auto rg = bf.header.read_groups.values.front;
        auto flow_order = rg.flow_order;
        auto key_sequence = rg.key_sequence;
        auto reads = array(bf.reads);

        auto read = reads[1];
        assert(!read.is_reverse_strand);

        alias TypeTuple!("FZ", "MD", 
                         Option.cigarExtra, 
                         Option.mdCurrentOp, 
                         Option.mdPreviousOp,
                         Option.mdNextOp) Options;

        auto bases = basesWith!Options(read, 
                                       arg!"flowOrder"(flow_order),
                                       arg!"keySequence"(key_sequence));
     
        typeof(bases.front) bfront;
        bases.constructFront(&bfront);

        assert(bfront.md_operation.is_match);
        assert(bfront.md_operation.match == 309);
        assert(bfront.md_operation_offset == 0);
        assert(bfront.previous_md_operation.isNull);
        assert(bfront.next_md_operation.is_deletion);
        assert(equal(bfront.next_md_operation.deletion, "G"));
        assert(equal(bfront.cigar_after, read.cigar[1 .. $]));
        assert(equal(drop(map!"a.reference_base"(bases), 191),
                     "-CCCGATTGGTCGTTGCTTTACGCTGATTGGCGAGTCCGGGGAACGTACCTTTGCTATCAGTCCAGGCCACATGAACCAGCTGCGGGCTGAAAGCATTCCGGAAGATGTGATTGCCGGACCTCGGCACTGGTTCTCACCTCATATCTGGTGCGTTGCAAGCCGGGTGAACCCATGCCGGAAGCACCATGAAAGCCATTGAGTACGCGAAGAAATATA"));
        assert(equal(bases, read.sequence));
        assert(equal(take(map!"a.flow_call.intensity_value"(bases), 92),
                     [219, 219, 194, 194, 92, 107, 83, 198, 198, 78, 
                     // A   A    C    C    T   G   A    T    T    A
                      292, 292, 292,  81, 79,  78, 95, 99, 315, 315, 315,
                     // C   C    C    A    T   C   A    G    T    T    T
                       89,  79, 290, 290, 290, 100, 209, 209, 87, 80,
                     // G   C    G    G    G   T    G    G    C   A
                      191, 191, 101, 179, 179, 210, 210, 99, 184, 184,
                     // C   C   A     T    T    G   G    T    A   A
                       90, 91, 193, 193, 66, 100, 112, 79, 108, 106, 212, 212,
                     // C   A   C    C    A   T    G    C   A    C    A    A
                       90, 96, 111, 94, 64, 94, 187, 187, 84, 110, 98, 102, 100,
                     // C   T   A    C   T   C   G    G    T   G    C   T    C
                       93, 89, 205, 205, 107, 98, 96, 91, 203, 203, 68, 180, 180,
                     // G   C   G    G    A    C   G   A   C    C    G   T    T
                       118, 246, 246, 91, 102, 94, 116, 90, 99, 101, 298, 298, 298
                     // C    G    G    T   G    C   T    G   C   T    G    G    G
                     ]));

        // bases must be the same
        foreach (r; reads) {
            if (r.is_unmapped) continue;
            if (r.cigar.length == 0) continue;
            if (r.is_reverse_strand) {
                bases = basesWith!Options(r, arg!"flowOrder"(flow_order), 
                                             arg!"keySequence"(key_sequence));
                // if reverse strand, bases are also reverse complemented
                assert(equal(bases, map!"a.complement"(retro(r.sequence))));
            } else {
                bases = basesWith!Options(r, arg!"flowOrder"(flow_order), 
                                             arg!"keySequence"(key_sequence));
                assert(equal(bases, r.sequence));
            }
        }
    }
}

void main() {
}
