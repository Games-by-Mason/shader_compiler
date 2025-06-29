layout(location = 0) in vec2 texcoord;
layout(location = 0) out vec4 composite;

void main() {
    // const bool strip = false;
    vec4 color = vec4(1);
    if (false) {
        color.r = sin(texcoord.x);
    }
    composite = color;
}
