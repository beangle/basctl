/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/** Unit tests for bas.mimetypes. */
module test.mimetypes_test;

import bas.mimetypes;

@("parse mime types lines") unittest {
  auto entries = parseMimeTypes("#comment\ntype=text/html   exts=html,htm\ntype=image/png  exts=png\n");
  assert(entries.length == 5);
  assert(entries[0].key == "text/html" && entries[0].mimeType == "text/html");
  assert(entries[1].key == "html" && entries[1].mimeType == "text/html");
  assert(entries[2].key == "htm" && entries[2].mimeType == "text/html");
  assert(entries[3].key == "image/png");
  assert(entries[4].key == "png" && entries[4].mimeType == "image/png");
}
