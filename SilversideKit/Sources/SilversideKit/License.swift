/// Silverside's license, the same text as LICENSE at the top of the repository (a test
/// checks it). The CLI has no resource bundle when it is installed alone, so the text
/// is in the code.
public enum SilversideLicense {
    public static let text = """
        Copyright 2026 Preston Landers

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
        associated documentation files (the “Software”), to deal in the Software without restriction, \
        including without limitation the rights to use, copy, modify, merge, publish, distribute, \
        sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial \
        portions of the Software.

        THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT \
        NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES \
        OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN \
        CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        The name "Silverside" and the icon and logo artwork (App/Silverside/AppIcon.icon and App/Icon/*.svg) \
        are not covered by this license. All rights reserved. If you distribute a modified version, give it \
        a different name and icon.

        The HDCD decoder in SilversideKit/Vendor/HDCD comes from FFmpeg and is under its own BSD license, in \
        that folder. The HDCD logo (App/Silverside/Assets.xcassets/HDCD.imageset) is a trademark of its owner \
        and is not covered by this license either.
        """

    /// The license of FFmpeg's HDCD decoder (`Vendor/HDCD/LICENSE`, which a test checks), which
    /// Silverside includes: its binary form must show it.
    public static let hdcdDecoder = """
        Copyright (C) 2010, Chris Moeller,
        All rights reserved.
        Optimizations by Gumboot
        Additional work by Burt P.
        Original code reverse engineered from HDCD decoder library by Christopher Key,
        which was likely reverse engineered from Windows Media Player.

        Redistribution and use in source and binary forms, with or without modification,
        are permitted provided that the following conditions are met:
          1. Redistributions of source code must retain the above copyright
             notice, this list of conditions and the following disclaimer.
          2. Redistributions in binary form must reproduce the above copyright
             notice, this list of conditions and the following disclaimer in the
             documentation and/or other materials provided with the distribution.
          3. The names of its contributors may not be used to endorse or promote
             products derived from this software without specific prior written
             permission.
        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
        "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
        LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
        A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
        CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
        EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
        PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
        PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
        LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
        NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """
}
