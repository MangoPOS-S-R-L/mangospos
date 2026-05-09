import 'package:supabase_flutter/supabase_flutter.dart';

class Employee {
  final String id;
  final String businessId;
  final String? userId;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String? nationalId;
  final String? gender;
  final String? address;
  final String status; // active | inactive | password_reset
  final DateTime? hireDate;
  final String? contractType;
  final String? department;
  final String? position;
  final String? workSchedule;
  final double? salaryBase;
  final String? payFrequency;
  final String? bankName;
  final String? bankAccount;
  final String? emergencyName;
  final String? emergencyRelation;
  final String? emergencyPhone;
  final String? pin;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<String> roles;

  Employee({
    required this.id,
    required this.businessId,
    this.userId,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    this.nationalId,
    this.gender,
    this.address,
    required this.status,
    this.hireDate,
    this.contractType,
    this.department,
    this.position,
    this.workSchedule,
    this.salaryBase,
    this.payFrequency,
    this.bankName,
    this.bankAccount,
    this.emergencyName,
    this.emergencyRelation,
    this.emergencyPhone,
    this.pin,
    required this.createdAt,
    this.updatedAt,
    required this.roles,
  });

  String get fullName => '$firstName $lastName'.trim();

  String get initials {
    String two = '';
    if (firstName.isNotEmpty) two += firstName[0];
    final ln = lastName.isNotEmpty
        ? lastName
        : (fullName.split(' ').length > 1 ? fullName.split(' ')[1] : '');
    if (ln.isNotEmpty) two += ln[0];
    return two.toUpperCase();
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    double? salary;
    final rawSalary = map['salary_base'];
    if (rawSalary is num) {
      salary = rawSalary.toDouble();
    } else if (rawSalary is String) {
      salary = double.tryParse(rawSalary);
    }

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value);
      return null;
    }

    return Employee(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      userId: map['user_id'] as String?,
      firstName: map['first_name'] as String? ?? '',
      lastName: map['last_name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      nationalId: map['national_id'] as String?,
      gender: map['gender'] as String?,
      address: map['address'] as String?,
      status: map['status'] as String? ?? 'active',
      hireDate: parseDate(map['hire_date']),
      contractType: map['contract_type'] as String?,
      department: map['department'] as String?,
      position: map['position'] as String?,
      workSchedule: map['work_schedule'] as String?,
      salaryBase: salary,
      payFrequency: map['pay_frequency'] as String?,
      bankName: map['bank_name'] as String?,
      bankAccount: map['bank_account'] as String?,
      emergencyName: map['emergency_name'] as String?,
      emergencyRelation: map['emergency_relation'] as String?,
      emergencyPhone: map['emergency_phone'] as String?,
      pin: map['pin'] as String?,
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
      updatedAt: parseDate(map['updated_at']),
      roles: (map['roles'] is List)
          ? List<String>.from(map['roles'])
          : const [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'business_id': businessId,
      'user_id': userId,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'national_id': nationalId,
      'gender': gender,
      'address': address,
      'status': status,
      'hire_date': hireDate?.toIso8601String(),
      'contract_type': contractType,
      'department': department,
      'position': position,
      'work_schedule': workSchedule,
      'salary_base': salaryBase,
      'pay_frequency': payFrequency,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'emergency_name': emergencyName,
      'emergency_relation': emergencyRelation,
      'emergency_phone': emergencyPhone,
      'pin': pin,
    };
  }
}

class EmployeeRepository {
  final SupabaseClient _client;
  EmployeeRepository(this._client);

  Future<List<Employee>> fetchEmployees({required String businessId}) async {
    final res = await _client
        .from('v_employees_summary')
        .select('*')
        .eq('business_id', businessId);

    final list = (res as List)
        .map((row) => Employee.fromMap(row as Map<String, dynamic>))
        .toList();

    return list;
  }

  Future<Employee> createEmployee({
    required String businessId,
    required String firstName,
    required String lastName,
    required String email,
    required String phone,
    String? nationalId,
    String? gender,
    String? address,
    String status = 'active',
    DateTime? hireDate,
    String? contractType,
    String? department,
    String? position,
    String? workSchedule,
    double? salaryBase,
    String? payFrequency,
    String? bankName,
    String? bankAccount,
    String? emergencyName,
    String? emergencyRelation,
    String? emergencyPhone,
    String? pin,
    String? password,
    String? primaryRole,
    List<String> roleIds = const [],
  }) async {
    // Single atomic RPC: crea auth.users + user_businesses + employees
    // + employee_roles + user_roles en una transacción. Si algo falla,
    // postgres revierte todo y no quedan filas huérfanas.
    final employeeData = <String, dynamic>{
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'phone': phone,
      'national_id': nationalId,
      'gender': gender,
      'address': address,
      'status': status,
      'hire_date': hireDate?.toIso8601String().split('T').first,
      'contract_type': contractType,
      'department': department,
      'position': position,
      'work_schedule': workSchedule,
      'salary_base': salaryBase?.toString(),
      'pay_frequency': payFrequency,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'emergency_name': emergencyName,
      'emergency_relation': emergencyRelation,
      'emergency_phone': emergencyPhone,
      'pin': pin,
    }..removeWhere((_, value) => value == null);

    final res = await _client.rpc(
      'fn_create_employee_with_access',
      params: {
        'p_business_id': businessId,
        'p_email': email,
        'p_password': (password != null && password.isNotEmpty) ? password : null,
        'p_employee_data': employeeData,
        'p_primary_role': primaryRole,
        'p_role_ids': roleIds.isEmpty ? null : roleIds,
      },
    );

    final result = Map<String, dynamic>.from(res as Map);
    final employeeMap = Map<String, dynamic>.from(result['employee'] as Map);
    return Employee.fromMap(employeeMap);
  }

  Future<void> updateEmployee({
    required String employeeId,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? nationalId,
    String? gender,
    String? address,
    String? status,
    DateTime? hireDate,
    String? contractType,
    String? department,
    String? position,
    String? workSchedule,
    double? salaryBase,
    String? payFrequency,
    String? bankName,
    String? bankAccount,
    String? emergencyName,
    String? emergencyRelation,
    String? emergencyPhone,
    String? pin,
  }) async {
    final update = <String, dynamic>{};

    if (firstName != null) update['first_name'] = firstName;
    if (lastName != null) update['last_name'] = lastName;
    if (email != null) update['email'] = email;
    if (phone != null) update['phone'] = phone;
    if (nationalId != null) update['national_id'] = nationalId;
    if (gender != null) update['gender'] = gender;
    if (address != null) update['address'] = address;
    if (status != null) update['status'] = status;
    if (hireDate != null) update['hire_date'] = hireDate.toIso8601String();
    if (contractType != null) update['contract_type'] = contractType;
    if (department != null) update['department'] = department;
    if (position != null) update['position'] = position;
    if (workSchedule != null) update['work_schedule'] = workSchedule;
    if (salaryBase != null) update['salary_base'] = salaryBase;
    if (payFrequency != null) update['pay_frequency'] = payFrequency;
    if (bankName != null) update['bank_name'] = bankName;
    if (bankAccount != null) update['bank_account'] = bankAccount;
    if (emergencyName != null) update['emergency_name'] = emergencyName;
    if (emergencyRelation != null) {
      update['emergency_relation'] = emergencyRelation;
    }
    if (emergencyPhone != null) update['emergency_phone'] = emergencyPhone;
    if (pin != null) update['pin'] = pin;

    if (update.isNotEmpty) {
      update['updated_at'] = DateTime.now().toIso8601String();
      await _client.from('employees').update(update).eq('id', employeeId);
    }
  }

  Future<void> updateEmployeeRoles({
    required String employeeId,
    required List<String> roleIds,
  }) async {
    // Eliminar roles existentes
    await _client.from('employee_roles').delete().eq('employee_id', employeeId);

    // Insertar nuevos roles
    if (roleIds.isNotEmpty) {
      final rows = roleIds
          .map((rid) => {'employee_id': employeeId, 'role_id': rid})
          .toList();
      await _client.from('employee_roles').insert(rows);
    }
  }

  Future<List<Map<String, dynamic>>> fetchRoles({
    required String businessId,
  }) async {
    final res = await _client
        .from('roles')
        .select('id, name, description, is_system')
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(res as List);
  }

  Future<void> ensureBusinessRoleDefaults({required String businessId}) async {
    await _client.rpc(
      'fn_seed_business_rbac_defaults',
      params: {'p_business_id': businessId},
    );
  }

  Future<Map<String, dynamic>> fetchUserAccessProfile({
    required String employeeId,
    required String businessId,
  }) async {
    final response = await _client.rpc(
      'fn_get_user_access_profile',
      params: {'p_employee_id': employeeId, 'p_business_id': businessId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> saveUserAccessProfile({
    required String employeeId,
    required String businessId,
    required List<String> roleIds,
    required String primaryRole,
    required Set<String> effectivePermissionCodes,
  }) async {
    await _client.rpc(
      'fn_save_user_access_profile',
      params: {
        'p_employee_id': employeeId,
        'p_business_id': businessId,
        'p_role_ids': roleIds,
        'p_primary_role': primaryRole,
        'p_effective_permission_codes': effectivePermissionCodes.toList(),
      },
    );
  }

  Future<void> updateUserPassword({
    required String userId,
    required String newPassword,
  }) async {
    await _client.rpc(
      'admin_update_user_password',
      params: {
        'target_user_id': userId,
        'new_password': newPassword,
      },
    );
  }

  Future<void> deleteEmployee({required String employeeId}) async {
    await _client.from('employees').delete().eq('id', employeeId);
  }
}
