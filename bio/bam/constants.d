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
module bio.bam.constants;

public import bio.core.bgzf.constants;

immutable BAM_MAGIC = "BAM\1";
immutable BAI_MAGIC = "BAI\1";

immutable ubyte BAM_SI1 = 66;
immutable ubyte BAM_SI2 = 67;
immutable ubyte[28] BAM_EOF = BGZF_EOF;

immutable BAI_MAX_BIN_ID = 37449;
immutable BAI_MAX_NONLEAF_BIN_ID = 4680;
immutable BAI_LINEAR_INDEX_WINDOW_SIZE = 16384;
