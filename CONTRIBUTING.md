# Contributing to Delphi Libraries Collection

Thank you for your interest in contributing! This document explains how to participate in this project.

## 📋 Code of Conduct

Be respectful, inclusive, and professional. We welcome developers of all skill levels.

## 🎯 How to Contribute

### 1. Report Bugs

Found a bug? Help us fix it:

1. Check existing [Issues](https://github.com/your-username/delphi-libraries/issues) first
2. Provide a clear title and description
3. Include steps to reproduce
4. Specify your Delphi version and platform (Win32/Win64/Linux64)

**Example:**
```
Title: MP3 Decoder crashes on MPEG2.5 files

Description:
When decoding MPEG2.5 11025 Hz files, the decoder throws an 
Access Violation in MP3Layer3.pas line 800.

Steps to reproduce:
1. Run MP3ToWAV.exe with any MPEG2.5 11025 Hz MP3 file
2. Observe crash at ~25% progress

Environment:
- Delphi 12 Athens
- Windows 10 x64
```

### 2. Request Features

Have a feature idea? Let us know:

1. Open a [GitHub Discussion](https://github.com/your-username/delphi-libraries/discussions)
2. Describe the feature and why it's useful
3. Provide examples or use cases

### 3. Submit Code

#### Prerequisites
- Delphi 12 Athens or compatible
- Git installed
- Understanding of Delphi Pascal

#### Steps

**Fork and Clone:**
```bash
git clone https://github.com/your-username/delphi-libraries.git
cd delphi-libraries
```

**Create a branch:**
```bash
git checkout -b feature/your-feature-name
# or for bugfixes:
git checkout -b fix/issue-description
```

**Make changes:**
- Edit source files in `src/` directories
- Follow coding standards (see below)
- Update documentation if needed

**Test:**
```bash
msbuild mp3-decoder\MP3ToWAV.dproj /p:Config=Release /p:Platform=Win64
```

**Commit:**
```bash
git add .
git commit -m "Description of changes

- Specific change 1
- Specific change 2

Fixes #123 (if fixing an issue)
```

**Push and PR:**
```bash
git push origin feature/your-feature-name
# Open a Pull Request on GitHub
```

---

## 📝 Coding Standards

### Delphi Style Guide

1. **Naming Conventions**
   ```pascal
   // Classes: PascalCase
   TMP3Decoder = class
   
   // Functions/Procedures: PascalCase
   procedure DecodeFrame(...);
   
   // Variables: camelCase (local) or PascalCase (fields)
   var localVar: Integer;
       FPrivateField: String;
   
   // Constants: UPPER_SNAKE_CASE
   const BUFFER_SIZE = 4096;
   ```

2. **File Organization**
   ```pascal
   unit MP3Types;
   
   {
     Unit description
     License: CC0 1.0 Universal
     Based on: [source if translated]
   }
   
   interface
   
   // Public declarations
   
   implementation
   
   // Implementation
   
   end.
   ```

3. **Comments**
   ```pascal
   // Single-line comments for brief notes
   
   // Multi-line comments for complex logic
   // Explain the "why", not the "what"
   
   { Pascal-style comments also acceptable }
   ```

4. **Formatting**
   ```pascal
   // Indent with 2 spaces (not tabs)
   if condition then
   begin
     Action1;
     Action2;
   end;
   
   // Line length: max 100 characters (soft), 120 hard limit
   var
     ReallyLongVariableName: TSomeComplexType;
     AnotherVariable: Integer;
   ```

5. **Error Handling**
   ```pascal
   // Check preconditions
   if not FileExists(FileName) then
     Exit; // or raise an exception
   
   try
     // Main logic
   finally
     // Cleanup (always executes)
   end;
   ```

### Documentation Standards

1. **Unit Headers**
   Every `.pas` file must have:
   ```pascal
   {
     UnitName.pas - Brief description
     
     Longer description of functionality and purpose.
     If translated: "Translated from [source]"
     
     License: CC0 1.0 Universal
     Original: [URL if applicable]
   }
   ```

2. **Function Headers**
   ```pascal
   { Decode a single MP3 frame
     @param BitStream The input bit stream
     @param Header The frame header (already parsed)
     @return Number of PCM samples decoded }
   function DecodeFrame(BitStream: TBitStream; 
                       const Header: THeader): Integer;
   ```

3. **README for Libraries**
   Each library folder must have a `README.md` with:
   - Brief description
   - Features
   - Usage example
   - Installation/building
   - License reference

---

## 📚 Adding a New Library

### Folder Structure
```
new-library/
├── README.md                 # Description, usage, features
├── LICENSE.md               # CC0 license declaration
├── src/
│   ├── Unit1.pas
│   ├── Unit2.pas
│   └── Program.dpr          # (optional) console/GUI app
├── samples/                 # (optional) test files
│   └── example-input.*
└── Project.dproj           # Delphi project file
```

### Checklist
- [ ] All source files have CC0 license header in comments
- [ ] README.md describes purpose, features, and usage
- [ ] LICENSE.md references CC0 1.0 Universal
- [ ] Code follows Delphi style guide above
- [ ] No external dependencies (or clearly documented)
- [ ] Compiles without errors in Win64 (minimum)
- [ ] Update root `README.md` with library info

### Example README Template

```markdown
# Library Name

Brief one-liner description.

## Features
- Feature 1
- Feature 2

## Usage
\`\`\`pascal
uses LibraryUnit;

procedure Example;
begin
  // Code example
end;
\`\`\`

## Building
\`\`\`bash
msbuild Project.dproj /p:Config=Release /p:Platform=Win64
\`\`\`

## License
CC0 1.0 Universal (Public Domain)
See LICENSE.md
```

---

## 🧪 Testing

### Unit Testing
If possible, include test files or sample data:
```
samples/
├── input-valid.ext
├── input-invalid.ext
└── README.txt (describe test cases)
```

### Build Testing
Ensure code compiles for:
- ✅ Win64 (required)
- ⚠️ Win32 (recommended)
- 🎯 Linux64 (optional)

### Quality Standards
- No compiler errors
- Minimal compiler warnings
- Clear, readable code
- Well-commented complex sections

---

## 🔄 Pull Request Process

1. **Before submitting:**
   - [ ] Code follows style guide
   - [ ] Compiles without errors
   - [ ] README/docs updated
   - [ ] Tests pass
   - [ ] License headers present

2. **Describe your PR:**
   ```markdown
   ## Description
   Briefly explain what this PR does.
   
   ## Related Issues
   Fixes #123 (if applicable)
   
   ## Changes
   - Change 1
   - Change 2
   
   ## Testing
   How did you test this?
   ```

3. **Review Process:**
   - Maintainers will review your code
   - Feedback may be requested
   - Once approved, your PR will be merged
   - You'll be credited in release notes

---

## 📜 License Requirements

**All contributions must be compatible with CC0 1.0 Universal (Public Domain).**

This means:
- ✅ Use public domain code
- ✅ Use CC0-licensed code
- ✅ Use MIT, Apache 2.0, GPL, BSD code (all compatible)
- ❌ Do NOT use proprietary or restrictive licenses

If your code is based on another source, include proper attribution in comments.

---

## 🚀 Becoming a Maintainer

Active contributors may be invited to maintain specific libraries. Benefits:
- Merge permission
- Library ownership
- Release authority

Contact the project owner if interested.

---

## 📞 Questions?

- **GitHub Issues**: For bug reports and feature requests
- **GitHub Discussions**: For questions and ideas
- **Direct Contact**: [your-email@example.com]

---

## ❤️ Thank You!

Thank you for contributing to Delphi Libraries Collection. Your efforts help make these tools better for everyone!

---

**Last Updated:** 2026-04-02
