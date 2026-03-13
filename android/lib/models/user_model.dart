// ========== FILE: lib/models/user_model.dart ==========

class UserModel {
  final String id;
  final String name;
  final String email;
  final String role;
  final String? city;
  final bool isActive;
  final DateTime? createdAt;

  const UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.city,
    required this.isActive,
    this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      role: json['role']?.toString() ?? 'user',
      city: json['city']?.toString(),
      isActive: json['is_active'] as bool? ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role,
      'city': city,
      'is_active': isActive,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  bool get isOperator => role == 'operator' || role == 'super_admin';
  bool get isAdmin => role == 'super_admin';

  String get initials {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words[0].isNotEmpty ? words[0][0].toUpperCase() : '?';
    }
    final first = words[0].isNotEmpty ? words[0][0].toUpperCase() : '';
    final second = words[1].isNotEmpty ? words[1][0].toUpperCase() : '';
    return '$first$second';
  }
}