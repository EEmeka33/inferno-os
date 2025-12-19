#!/bin/bash
set -e

echo "=========================================="
echo "Inferno OS Installation Script"
echo "=========================================="
echo ""

# Prerequisites
echo "📦 Installing dependencies..."
sudo dpkg --add-architecture i386 2>/dev/null || true
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential git libx11-dev libfreetype6-dev pkg-config python3 \
    gcc-multilib libc6-i386 libc6-dev-i386 \
    libx11-dev:i386 libxext-dev:i386

# Clone with submodules
echo "📥 Cloning Inferno OS repository..."
mkdir -p ~/inferno-project
cd ~/inferno-project

if [ ! -d inferno-os ]; then
    git clone --recursive https://github.com/EEmeka33/inferno-os.git
else
    echo "   Repository already exists, skipping clone"
fi

cd inferno-os

# Configure mkconfig
echo "⚙️  Configuring mkconfig..."
sed -i "s|^ROOT=.*|ROOT=$PWD|" mkconfig
sed -i 's/^SYSHOST=.*/SYSHOST=Linux/' mkconfig
sed -i 's/^SYSTARG=.*/SYSTARG=Linux/' mkconfig
sed -i 's/^OBJTYPE=.*/OBJTYPE=386/' mkconfig
echo "   ✅ mkconfig configured"

# Run makemk
echo "⚙️  Running makemk.sh..."
./makemk.sh
echo "   ✅ makemk.sh completed"

# Set environment
export SYSTARG=Linux
export OBJTYPE=386
export PATH=$PATH:$PWD/Linux/386/bin

echo "🔧 Build environment: SYSTARG=$SYSTARG, OBJTYPE=$OBJTYPE"

# Apply initial fixes BEFORE build
echo "🔨 Applying initial fixes..."

# CRITICAL: Patch the mkfile template BEFORE build (so mk nuke uses it)
# This ensures -fcommon is in all generated mkfiles
if ! grep -q "\-fcommon" mkfiles/mkfile-Linux-386; then
    python3 << 'PYTHON_EOF'
with open('mkfiles/mkfile-Linux-386', 'r') as f:
    lines = f.readlines()

# Find the line with -DLINUX_386 and add -fcommon after it
for i, line in enumerate(lines):
    if line.rstrip() == '\t\t-DLINUX_386':
        # Replace this line with continuation and add -fcommon
        lines[i] = '\t\t-DLINUX_386\\\n'
        lines.insert(i + 1, '\t\t-fcommon\n')
        break

with open('mkfiles/mkfile-Linux-386', 'w') as f:
    f.writelines(lines)
PYTHON_EOF
    echo "   ✅ Added -fcommon to mkfile-Linux-386 template"
fi

# Add -pthread to LDFLAGS
if ! grep -q "^LDFLAGS=" emu/Linux/mkfile; then
    sed -i '/^CFLAGS=/a LDFLAGS=-pthread' emu/Linux/mkfile
    echo "   ✅ Added LDFLAGS=-pthread"
else
    if ! grep -q "LDFLAGS=.*pthread" emu/Linux/mkfile; then
        sed -i 's/^LDFLAGS=/LDFLAGS=-pthread /' emu/Linux/mkfile
        echo "   ✅ Updated LDFLAGS with -pthread"
    fi
fi

# Allow multiple definitions in linker command
if ! grep -q "allow-multiple-definition" emu/Linux/mkfile; then
    sed -i 's/\$LD \$LDFLAGS -o \$target/\$LD \$LDFLAGS -Wl,--allow-multiple-definition -o \$target/' emu/Linux/mkfile
    echo "   ✅ Added -Wl,--allow-multiple-definition to linker"
fi

# Fix Pointer typedefs
if ! grep -q "typedef.*Pointer" libinterp/tk.c; then
    LINE=$(grep -n "#include" libinterp/tk.c | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ] && [ "$LINE" -gt 0 ]; then
        sed -i "$((LINE+1))i typedef void* Pointer;" libinterp/tk.c
        echo "   ✅ Added Pointer typedef to tk.c"
    fi
fi

if ! grep -q "typedef.*Pointer" libtk/utils.c; then
    LINE=$(grep -n "#include" libtk/utils.c | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ] && [ "$LINE" -gt 0 ]; then
        sed -i "$((LINE+1))i typedef void* Pointer;" libtk/utils.c
        echo "   ✅ Added Pointer typedef to utils.c"
    fi
fi

if ! grep -q "typedef struct Pointer" emu/port/fns.h; then
    LINENUM=$(grep -n "extern Pointer" emu/port/fns.h | head -1 | cut -d: -f1)
    if [ -n "$LINENUM" ] && [ "$LINENUM" -gt 0 ]; then
        sed -i "$((LINENUM))i typedef struct Pointer Pointer;" emu/port/fns.h
        echo "   ✅ Added Pointer forward declaration"
    fi
fi

# Fix type mismatches
sed -i 's/extern Pointer tkstylus;/extern int tkstylus;/' emu/port/fns.h
sed -i 's/extern Pointer tkfont;/extern char* tkfont;/' emu/port/fns.h
echo "   ✅ Fixed tkstylus/tkfont types"

# Fix coherence declaration
sed -i 's/^void.*(\*coherence)(void);/extern void    (*coherence)(void);/' emu/port/fns.h
echo "   ✅ Fixed coherence declaration"

# Build
echo ""
echo "🏗️  Building Inferno OS..."
echo ""

mk nuke

# CRITICAL: After nuke, reapply essential source fixes
echo "   Reapplying source fixes after nuke..."

# THE REAL FIX: Move pthread_yield macro OUTSIDE #ifdef __NetBSD__
# The macro is currently inside #ifdef __NetBSD__, so on Linux it doesn't exist
# Solution: Define it outside the ifdef, right after semaphore.h
LINE=$(grep -n "#include.*<semaphore.h>" emu/port/kproc-pthreads.c | cut -d: -f1)
if [ -n "$LINE" ]; then
    # Add sched.h and pthread_yield definition BEFORE the #ifdef
    # Check if pthread_yield is already defined outside ifdef
    if ! sed -n "1,15p" emu/port/kproc-pthreads.c | grep -q "#define pthread_yield"; then
        # Insert after semaphore.h
        sed -i "${LINE}a #include <sched.h>" emu/port/kproc-pthreads.c
        sed -i "$((LINE+1))a #define pthread_yield() (sched_yield())" emu/port/kproc-pthreads.c
        echo "   ✅ Added pthread_yield macro outside #ifdef"
    fi
fi

# Add coherence and nofence to kproc-pthreads.c
if ! grep -q "void.*coherence" emu/port/kproc-pthreads.c; then
    cat >> emu/port/kproc-pthreads.c << 'EOF'

void nofence(void) { }
void (*coherence)(void) = nofence;
EOF
    echo "   ✅ Added nofence/coherence to kproc-pthreads.c"
fi

# Remove nofence from main.c (duplicate)
if grep -q "^void nofence" emu/port/main.c; then
    sed -i '/^void nofence/,/^}$/d' emu/port/main.c
    echo "   ✅ Removed nofence from main.c"
fi

mk install

# Verify
echo ""
if [ -f Linux/386/bin/emu ]; then
    SIZE=$(ls -lh Linux/386/bin/emu | awk '{print $5}')
    echo "✅ SUCCESS! Inferno compiled ($SIZE)"
    echo ""
    echo "🚀 To run:"
    echo "   export PATH=\$PATH:$PWD/Linux/386/bin"
    echo "   emu"
else
    echo "❌ Build failed"
    exit 1
fi
