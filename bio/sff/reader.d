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
module bio.sff.reader;

public import bio.sff.index;
import bio.sff.read;
import bio.sff.readrange;
import bio.sff.constants;

import bio.core.utils.stream;
import std.stream;
import std.system;
import std.range;
import std.exception;

/// SFF file reader
class SffReader {

    /// Open file by filename
    this(string filename) {
        _filename = filename;

        _readHeader();
    }

    /// Reads
    auto reads() @property {
        auto stream = new bio.core.utils.stream.File(filename);
        Stream sff = new EndianStream(stream, Endian.bigEndian);

        sff.seekSet(_header_length);
        auto sff_reads = SffReadRange(sff, cast(ushort)_flow_chars.length, _index_location);
        return takeExactly(sff_reads, _n_reads);
    }

    ///
    SffRead getReadAtOffset(size_t offset) {
        auto stream = new bio.core.utils.stream.File(filename);
        Stream sff = new EndianStream(stream, Endian.bigEndian);

        sff.seekSet(offset);
        auto read = SffReadRange(sff, cast(ushort)_flow_chars.length, _index_location).front;
        sff.close();
        return read;
    }

    /// File name
    string filename() @property const {
        return _filename;
    }

    /// Location of the index (if included).
    IndexLocation index_location() @property const {
        return _index_location;
    }

    ///
    bool has_index() @property const {
        return _index_location.offset != 0 && _index_location.length != 0;
    }

    /// Set index location (saves new index location to the file)
    void index_location(IndexLocation location) @property {
        _index_location = location;

        // offset spans 8 bytes (8 .. 16),
        // length spans 4 bytes (16 .. 20)

        auto stream = new bio.core.utils.stream.File(filename, "r+");
        stream.seekSet(8);
        auto endian_stream = new EndianStream(stream, Endian.bigEndian);
        endian_stream.write(location.offset);
        endian_stream.write(location.length);
        endian_stream.close();
    }

    /// Nucleotides used for each flow of each read
    string flow_order() @property const {
        return _flow_chars;
    }

    /// Nucleotide bases of the key sequence used for each read
    string key_sequence() @property const {
        return _key_sequence;
    }

    private {
        string _filename;

        uint _magic_number;
        char[4] _version;

        uint _n_reads;
        ushort _header_length;

        string _flow_chars;
        string _key_sequence;

        IndexLocation _index_location;

        void _readHeader() {
            auto stream = new bio.core.utils.stream.File(_filename);
            auto sff = new EndianStream(stream, Endian.bigEndian);
            
            sff.read(_magic_number);
            enforce(_magic_number == SFF_MAGIC, "Wrong magic number, expected 0x2E736666");

            sff.readExact(_version.ptr, 4);
            enforce(_version == SFF_VERSION, "Unsupported version, expected 1");

            sff.read(_index_location.offset);
            sff.read(_index_location.length);

            sff.read(_n_reads);
            sff.read(_header_length);

            ushort _key_length;
            ushort _number_of_flows;
            ubyte _flowgram_format_code;

            sff.read(_key_length);
            sff.read(_number_of_flows);
            sff.read(_flowgram_format_code);
            enforce(_flowgram_format_code == 1, 
                    "Flowgram format codes other than 1 are not supported");

            _flow_chars = cast(string)sff.readString(_number_of_flows);
            _key_sequence = cast(string)sff.readString(_key_length);
        }
    }
}
