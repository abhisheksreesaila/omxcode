uniform sampler2D picture;
in vec2 uv;
out vec4 colour;
void main() { colour = texture(picture, uv); }
